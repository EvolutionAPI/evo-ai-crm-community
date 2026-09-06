# Despacha os 8 passos do "Setup Google Ads" (Google::AdsInfrastructureService)
# por `acao`, mesmo estilo dos outros controllers de infraestrutura.
class Api::V1::Reports::AdsInfrastructureController < Api::V1::BaseController
  def handle
    service = Google::AdsInfrastructureService.new

    case params[:acao]
    when 'criar_sub_conta'
      respond(service.create_customer_client(
        descriptive_name: params.require(:descriptive_name),
        currency_code: params.require(:currency_code),
        time_zone: params.require(:time_zone)
      ))
    when 'criar_conversao'
      respond(service.create_conversion_action(customer_id: params.require(:customer_id), name: params.require(:name)))
    when 'ativar_conversoes_aprimoradas'
      respond(service.enable_enhanced_conversions(
        customer_id: params.require(:customer_id),
        conversion_action_resource: params.require(:conversion_action_resource)
      ))
    when 'vincular_ga4'
      respond(service.link_ga4(customer_id: params.require(:customer_id), ga4_property_id: params.require(:ga4_property_id)))
    when 'configurar_tracking_template'
      respond(service.set_tracking_template(customer_id: params.require(:customer_id), tracking_template: params.require(:tracking_template)))
    when 'criar_lista_remarketing'
      respond(service.create_remarketing_list(customer_id: params.require(:customer_id), name: params.require(:name)))
    when 'criar_sitelink'
      respond(service.create_sitelink_asset(
        customer_id: params.require(:customer_id),
        link_text: params.require(:link_text),
        final_url: params.require(:final_url)
      ))
    when 'vincular_mcc'
      respond(service.link_manager(customer_id: params.require(:customer_id)))
    else
      error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, "Ação desconhecida: #{params[:acao]}", status: :unprocessable_entity)
    end
  end

  private

  def respond(result)
    if result.success
      render json: result.data
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway)
    end
  end
end
