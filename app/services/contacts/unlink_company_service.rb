# Service Object para desvincular pessoa de empresa
class Contacts::UnlinkCompanyService
  def initialize(contact:, company:, account: nil)
    @contact = contact
    @company = company
  end

  def perform
    validate_params!

    ActiveRecord::Base.transaction do
      unlink_company
      publish_events
    end

    success_response
  rescue StandardError => e
    error_response(e.message)
  end

  private

  attr_reader :contact, :company

  def validate_params!
    raise 'Not linked' unless contact.companies.include?(company)
  end

  def unlink_company
    ContactCompany.where(
      contact: contact,
      company: company
    ).destroy_all
  end

  def publish_events
    Rails.configuration.dispatcher.dispatch(
      'contact_company_unlinked',
      Time.zone.now,
      contact: contact,
      company: company
    )
  end

  def success_response
    { success: true, contact: contact.reload }
  end

  def error_response(message)
    { success: false, error: message }
  end
end
