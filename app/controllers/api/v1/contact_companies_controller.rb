class Api::V1::ContactCompaniesController < Api::V1::BaseController
  require_permissions({
                        create: 'contacts.update',
                        destroy: 'contacts.update'
                      })

  before_action :fetch_contact
  before_action :fetch_company, only: [:create, :destroy]

  def create
    service_result = Contacts::LinkCompanyService.new(
      contact: @contact,
      company: @company,

    ).perform

    if service_result[:success]
      success_response(
        data: {
          contact: {
            id: @contact.id,
            name: @contact.name,
            type: @contact.type
          },
          company: {
            id: @company.id,
            name: @company.name,
            type: @company.type
          }
        },
        message: 'Contact linked to company successfully'
      )
    else
      error_response(
        ApiErrorCodes::BUSINESS_RULE_VIOLATION,
        service_result[:error]
      )
    end
  end

  def destroy
    service_result = Contacts::UnlinkCompanyService.new(
      contact: @contact,
      company: @company,

    ).perform

    if service_result[:success]
      success_response(
        data: {
          contact: {
            id: @contact.id,
            name: @contact.name,
            type: @contact.type
          },
          company: {
            id: @company.id,
            name: @company.name,
            type: @company.type
          }
        },
        message: 'Contact unlinked from company successfully'
      )
    else
      error_response(
        ApiErrorCodes::BUSINESS_RULE_VIOLATION,
        service_result[:error]
      )
    end
  end

  private

  def fetch_contact
    @contact = Contact.find(params[:contact_id])
  end

  def fetch_company
    @company = Contact.find(params[:company_id] || params[:id])
  end
end

