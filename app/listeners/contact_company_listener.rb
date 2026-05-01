class ContactCompanyListener < BaseListener
  include Singleton

  def contact_company_linked(event)
    contact = event.data[:contact]
    company = event.data[:company]
    account = event.data[:account] || single_tenant_account

    return unless contact.present? && company.present? && account.present?

    Rails.logger.info "ContactCompanyListener - contact_company_linked: contact=#{contact.id}, company=#{company.id}"

    broadcast_contact_company_event(account, contact, company, 'contact_company_linked')
  rescue StandardError => e
    Rails.logger.error "ContactCompanyListener - contact_company_linked failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  def contact_company_unlinked(event)
    contact = event.data[:contact]
    company = event.data[:company]
    account = event.data[:account] || single_tenant_account

    return unless contact.present? && company.present? && account.present?

    Rails.logger.info "ContactCompanyListener - contact_company_unlinked: contact=#{contact.id}, company=#{company.id}"

    broadcast_contact_company_event(account, contact, company, 'contact_company_unlinked')
  rescue StandardError => e
    Rails.logger.error "ContactCompanyListener - contact_company_unlinked failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  def contacts_bulk_transferred(event)
    contacts = event.data[:contacts]
    from_company = event.data[:from_company]
    to_company = event.data[:to_company]
    account = event.data[:account] || single_tenant_account

    return unless contacts.present? && from_company.present? && to_company.present? && account.present?

    Rails.logger.info "ContactCompanyListener - contacts_bulk_transferred: #{contacts.count} contacts " \
                      "from company=#{from_company.id} to company=#{to_company.id}"

    broadcast_bulk_transfer_event(account, contacts, from_company, to_company)
  rescue StandardError => e
    Rails.logger.error "ContactCompanyListener - contacts_bulk_transferred failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
  end

  private

  def broadcast_contact_company_event(account, contact, company, event_type)
    tokens = all_user_tokens

    payload = {
      contact: contact_data(contact),
      company: contact_data(company),
      event_type: event_type
    }

    broadcast(account, tokens, event_type.upcase, payload)
  end

  def broadcast_bulk_transfer_event(account, contacts, from_company, to_company)
    tokens = all_user_tokens

    payload = {
      contacts: contacts.map { |c| { id: c.id, name: c.name } },
      from_company: contact_data(from_company),
      to_company: contact_data(to_company),
      count: contacts.count
    }

    broadcast(account, tokens, 'CONTACTS_BULK_TRANSFERRED', payload)
  end

  def contact_data(contact)
    {
      id: contact.id,
      name: contact.name,
      email: contact.email,
      type: contact.type,
      company_contacts_count: contact.type == 'company' ? contact.company_contacts.size : 0
    }
  end

  def all_user_tokens
    User.pluck(:pubsub_token).compact.uniq
  end

  def broadcast(account, tokens, event_type, payload)
    return if tokens.blank?

    ::ActionCableBroadcastJob.perform_later(tokens.uniq, event_type, payload)
  end
end

