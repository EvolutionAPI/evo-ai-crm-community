# frozen_string_literal: true

# Envia o resumo de um pedido do cardápio digital para o WhatsApp configurado
# em Organização > Cardápio Digital (MENU_ORDER_INBOX_ID = canal que envia,
# MENU_WHATSAPP_NUMBER = número da loja que recebe). Reaproveita a mesma
# infraestrutura de contato/conversa/mensagem usada pelo resto do CRM
# (ContactInboxWithContactBuilder + ConversationBuilder), então o envio de
# fato passa pelos providers já existentes (Evolution/Z-API/Cloud/etc) via
# SendReplyJob, sem reinventar a integração com WhatsApp.
class DigitalMenu::OrderNotificationService
  Result = Struct.new(:success, :error, keyword_init: true)

  def initialize(customer:, items:, payment_method:, notes:)
    @customer = customer
    @items = items
    @payment_method = payment_method
    @notes = notes
  end

  def call
    inbox_id = GlobalConfigService.load('MENU_ORDER_INBOX_ID', nil)
    target_phone = GlobalConfigService.load('MENU_WHATSAPP_NUMBER', nil)
    return Result.new(success: false, error: 'not_configured') if inbox_id.blank? || target_phone.blank?

    inbox = Inbox.find_by(id: inbox_id)
    return Result.new(success: false, error: 'inbox_not_found') unless inbox

    contact_inbox = ContactInboxWithContactBuilder.new(
      inbox: inbox,
      contact_attributes: { phone_number: normalize_phone(target_phone), name: contact_name }
    ).perform
    return Result.new(success: false, error: 'contact_error') unless contact_inbox

    # O contato é o número da loja (destino de todos os pedidos), então é
    # reaproveitado a cada pedido — o builder só define o nome na criação, e
    # sem isso o card de conversas ficaria travado no nome do primeiro
    # cliente que já fez pedido. Atualiza pra sempre refletir quem pediu por
    # último.
    contact_inbox.contact.update(name: contact_name) if contact_inbox.contact.name != contact_name

    conversation = ConversationBuilder.new(
      params: ActionController::Parameters.new({}).permit!,
      contact_inbox: contact_inbox
    ).perform

    conversation.messages.create!(
      inbox_id: conversation.inbox_id,
      message_type: :outgoing,
      content: build_template
    )

    Result.new(success: true)
  rescue StandardError => e
    Rails.logger.error("DigitalMenu::OrderNotificationService failed: #{e.class}: #{e.message}")
    Result.new(success: false, error: e.message)
  end

  private

  def contact_name
    name = @customer[:full_name].to_s.strip
    name.present? ? "#{name} - Cardápio Digital" : 'Pedidos - Cardápio Digital'
  end

  def normalize_phone(phone)
    digits = phone.to_s.gsub(/\D/, '')
    digits = "55#{digits}" unless digits.start_with?('55')
    "+#{digits}"
  end

  def build_template
    lines = []
    lines << '🛎️ *Novo pedido — Cardápio Digital*'
    lines << ''
    lines << "*Cliente:* #{@customer[:full_name]}"
    lines << "*Telefone:* #{@customer[:phone]}"
    address_line = "#{@customer[:address]}, #{@customer[:number]}"
    address_line += " - #{@customer[:neighborhood]}" if @customer[:neighborhood].present?
    lines << "*Endereço:* #{address_line}"
    lines << "*Cidade:* #{@customer[:city]}/#{@customer[:state]}" if @customer[:city].present?
    lines << ''
    lines << '*Itens:*'
    total = 0.0
    @items.each do |item|
      quantity = item[:quantity].to_i
      price = item[:price].to_f
      subtotal = quantity * price
      total += subtotal
      lines << "• #{quantity}x #{item[:name]} — #{format_currency(subtotal)}"
    end
    lines << ''
    lines << "*Total:* #{format_currency(total)}"
    lines << "*Pagamento:* #{@payment_method}"
    lines << "*Observações:* #{@notes}" if @notes.present?
    lines.join("\n")
  end

  def format_currency(value)
    format('R$ %.2f', value).tr('.', ',')
  end
end
