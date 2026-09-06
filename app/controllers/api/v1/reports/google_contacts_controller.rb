# Endpoint único (despacha por `acao`) atrás da seção "Contatos Google" em
# Contatos: diff CRM x Google Contatos (People API) e diff CRM x agenda do
# WhatsApp conectado (Evolution API) — pra achar contatos que ficaram de
# fora de um lado ou de outro e importar/adicionar em lote.
class Api::V1::Reports::GoogleContactsController < Api::V1::BaseController
  MAX_LIST = 300

  def handle
    case params[:acao]
    when 'status'
      render json: { success: true, data: { google_connected: google_service.connected?, whatsapp_connected: whatsapp_channel.present? } }
    when 'diff_google'
      diff_google
    when 'importar_do_google'
      importar_do_google
    when 'adicionar_ao_google'
      adicionar_ao_google
    when 'diff_whatsapp'
      diff_whatsapp
    when 'importar_whatsapp'
      importar_whatsapp
    else
      error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, "Ação desconhecida: #{params[:acao]}", status: :unprocessable_entity)
    end
  end

  private

  def google_service
    @google_service ||= Google::ContactsService.new
  end

  def whatsapp_channel
    @whatsapp_channel ||= Channel::Whatsapp.find_by(provider: 'evolution')
  end

  def normalized_phone(raw)
    return nil if raw.blank?

    digits = raw.to_s.gsub(/[^\d+]/, '')
    digits = "+#{digits}" unless digits.start_with?('+')
    digits
  end

  def crm_phone_set
    Contact.where.not(phone_number: [nil, '']).pluck(:phone_number).map { |p| normalized_phone(p) }.to_set
  end

  def crm_email_set
    Contact.where.not(email: [nil, '']).pluck(:email).map(&:downcase).to_set
  end

  def diff_google
    unless google_service.connected?
      return render json: { success: true, data: { connected: false, only_in_google: [], only_in_crm: [] } }
    end

    result = google_service.list_contacts
    return respond_error(result) unless result.success

    phones = crm_phone_set
    emails = crm_email_set

    only_in_google = result.data.select do |c|
      phone_match = c[:phone].present? && phones.include?(normalized_phone(c[:phone]))
      email_match = c[:email].present? && emails.include?(c[:email].to_s.downcase)
      c[:name].present? && !phone_match && !email_match
    end.first(MAX_LIST)

    google_phones = result.data.filter_map { |c| normalized_phone(c[:phone]) }.to_set
    google_emails = result.data.filter_map { |c| c[:email]&.downcase }.to_set

    only_in_crm = Contact.where(type: 'person')
                          .where('phone_number IS NOT NULL OR email IS NOT NULL')
                          .order(updated_at: :desc)
                          .limit(2000)
                          .select do |c|
      phone_norm = normalized_phone(c.phone_number)
      email_norm = c.email&.downcase
      phone_match = phone_norm.present? && google_phones.include?(phone_norm)
      email_match = email_norm.present? && google_emails.include?(email_norm)
      !phone_match && !email_match
    end.first(MAX_LIST).map { |c| { id: c.id, name: c.name, phone: c.phone_number, email: c.email } }

    render json: { success: true, data: { connected: true, only_in_google: only_in_google, only_in_crm: only_in_crm } }
  end

  def importar_do_google
    name = params.require(:name)
    phone = normalized_phone(params[:phone])
    email = params[:email].presence

    contact = Contact.new(name: name, phone_number: phone, email: email)
    if contact.save
      render json: { success: true, data: { id: contact.id, name: contact.name } }
    else
      render json: { success: false, message: contact.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end
  end

  def adicionar_ao_google
    contact = Contact.find(params.require(:contact_id))
    result = google_service.create_contact(name: contact.name.presence || 'Sem nome', phone: contact.phone_number, email: contact.email)
    respond_result(result)
  rescue ActiveRecord::RecordNotFound
    render json: { success: false, message: 'Contato não encontrado' }, status: :not_found
  end

  def diff_whatsapp
    channel = whatsapp_channel
    unless channel && channel.provider_service.respond_to?(:fetch_contacts)
      return render json: { success: true, data: { connected: false, only_in_whatsapp: [], reason: 'no_channel' } }
    end

    wa_contacts = channel.provider_service.fetch_contacts
    if wa_contacts.nil?
      return render json: { success: true, data: { connected: false, only_in_whatsapp: [], reason: 'instance_unreachable' } }
    end

    phones = crm_phone_set

    only_in_whatsapp = wa_contacts.select { |c| !phones.include?(normalized_phone(c[:phone])) }
                                   .uniq { |c| c[:phone] }
                                   .first(MAX_LIST)

    render json: { success: true, data: { connected: true, only_in_whatsapp: only_in_whatsapp } }
  end

  def importar_whatsapp
    contacts_params = params.require(:contacts)
    created = 0
    errors = []

    contacts_params.each do |c|
      phone = normalized_phone(c[:phone])
      next if phone.blank?

      contact = Contact.new(name: c[:name].presence || phone, phone_number: phone)
      if contact.save
        created += 1
      else
        errors << { phone: phone, message: contact.errors.full_messages.join(', ') }
      end
    end

    render json: { success: true, data: { created: created, errors: errors } }
  end

  def respond_result(result)
    if result.success
      render json: { success: true, data: result.data }
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway)
    end
  end
  alias respond_error respond_result
end
