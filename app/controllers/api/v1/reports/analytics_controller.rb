# Serve dados do Google Analytics (GA4) ao vivo — ver
# Google::AnalyticsInsightsService. Sem tab própria no relatório ainda
# (nenhuma das ferramentas existentes pedia isso); endpoint pronto pra uso
# assim que houver um lugar definido na UI pra mostrar.
class Api::V1::Reports::AnalyticsController < Api::V1::BaseController
  def properties
    respond(Google::AnalyticsInsightsService.new.list_properties)
  end

  def overview
    service = Google::AnalyticsInsightsService.new
    result = service.traffic_overview(
      property_id: params.require(:property_id),
      date_start: params.require(:date_start),
      date_stop: params.require(:date_stop)
    )
    respond(result)
  end

  def by_channel
    service = Google::AnalyticsInsightsService.new
    result = service.traffic_by_channel(
      property_id: params.require(:property_id),
      date_start: params.require(:date_start),
      date_stop: params.require(:date_stop)
    )
    respond(result)
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
