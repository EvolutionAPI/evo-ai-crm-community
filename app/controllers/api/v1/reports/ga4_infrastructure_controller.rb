# Despacha os 8 passos do "Setup GA4" (Google::Ga4InfrastructureService) por
# `acao`, mesmo estilo do Api::V1::Reports::MetaInfrastructureController.
class Api::V1::Reports::Ga4InfrastructureController < Api::V1::BaseController
  def handle
    service = Google::Ga4InfrastructureService.new

    case params[:acao]
    when 'lista_contas'
      respond(service.list_accounts)
    when 'criar_conta'
      respond(service.create_account(display_name: params.require(:display_name)))
    when 'criar_propriedade'
      respond(service.create_property(
        account_name: params.require(:account_name),
        display_name: params.require(:display_name),
        time_zone: params.require(:time_zone),
        currency_code: params.require(:currency_code)
      ))
    when 'criar_fluxo_web'
      respond(service.create_web_data_stream(
        property_id: params.require(:property_id),
        display_name: params.require(:display_name),
        default_uri: params.require(:default_uri)
      ))
    when 'ativar_medicao_avancada'
      respond(service.enable_enhanced_measurement(stream_id: params.require(:stream_id)))
    when 'criar_dimensoes'
      respond(service.create_custom_dimensions(property_id: params.require(:property_id), names: Array(params.require(:names))))
    when 'criar_eventos_conversao'
      respond(service.create_conversion_events(property_id: params.require(:property_id), event_names: Array(params.require(:event_names))))
    when 'vincular_google_ads'
      respond(service.link_google_ads(property_id: params.require(:property_id), customer_id: params.require(:customer_id)))
    when 'gerar_secret_measurement_protocol'
      respond(service.create_measurement_protocol_secret(stream_id: params.require(:stream_id), display_name: params[:display_name].presence || 'Server-Side CRM Secret'))
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
