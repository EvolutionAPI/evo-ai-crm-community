# Serve a aba "Google Ads" (Relatórios) chamando a Google Ads API ao vivo a
# cada request, igual ao workflow n8n "Google Ads Relatorio" fazia — só que
# direto do backend, sem n8n. Ver Google::AdsInsightsService.
class Api::V1::Reports::GoogleAdsController < Api::V1::BaseController
  MICROS = 1_000_000.0

  def insights
    service = Google::AdsInsightsService.new
    date_start = params.require(:date_start)
    date_stop = params.require(:date_stop)

    campaigns_result = service.campaigns(date_start: date_start, date_stop: date_stop)
    return respond_error(campaigns_result) unless campaigns_result.success

    terms_impressions = service.top_search_terms(date_start: date_start, date_stop: date_stop, order_by: 'metrics.impressions')
    terms_clicks = service.top_search_terms(date_start: date_start, date_stop: date_stop, order_by: 'metrics.clicks')

    campaigns = campaigns_result.data.map { |row| serialize_campaign(row) }

    render json: {
      totals: {
        cost: campaigns.sum { |c| c[:custo] },
        clicks: campaigns.sum { |c| c[:cliques] },
        impressions: campaigns.sum { |c| c[:impressoes] },
        conversions: campaigns.sum { |c| c[:conversoes] }
      },
      campaigns: campaigns,
      top_terms_by_impressions: terms_impressions.success ? terms_impressions.data.map { |r| serialize_term(r) } : [],
      top_terms_by_clicks: terms_clicks.success ? terms_clicks.data.map { |r| serialize_term(r) } : []
    }
  end

  private

  def respond_error(result)
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway)
  end

  def serialize_campaign(row)
    campaign = row['campaign'] || {}
    metrics = row['metrics'] || {}
    {
      campanha: campaign['name'],
      status: campaign['status'],
      cliques: metrics['clicks'].to_i,
      impressoes: metrics['impressions'].to_i,
      custo: (metrics['costMicros'].to_i / MICROS).round(2),
      conversoes: metrics['conversions'].to_f.round(2)
    }
  end

  def serialize_term(row)
    search_term_view = row['searchTermView'] || {}
    campaign = row['campaign'] || {}
    metrics = row['metrics'] || {}
    {
      termo: search_term_view['searchTerm'],
      campanha: campaign['name'],
      impressoes: metrics['impressions'].to_i,
      cliques: metrics['clicks'].to_i
    }
  end
end
