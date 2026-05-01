# Service Object para vincular pessoa a empresa
class Contacts::LinkCompanyService
  def initialize(contact:, company:, account: nil)
    @contact = contact
    @company = company
  end

  def perform
    validate_params!

    ActiveRecord::Base.transaction do
      link_company
      publish_events
    end

    success_response
  rescue StandardError => e
    error_response(e.message)
  end

  private

  attr_reader :contact, :company

  def validate_params!
    raise 'Contact must be a person' unless contact.person?
    raise 'Company must be a company' unless company.company?
    raise 'Already linked' if contact.companies.include?(company)
  end

  def link_company
    ContactCompany.create!(
      contact: contact,
      company: company
    )
  end

  def publish_events
    Rails.configuration.dispatcher.dispatch(
      'contact_company_linked',
      Time.zone.now,
      contact: contact,
      company: company
    )
  end

  def success_response
    { success: true, contact: contact.reload, company: company }
  end

  def error_response(message)
    { success: false, error: message }
  end
end
