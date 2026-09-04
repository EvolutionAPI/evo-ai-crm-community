# Serve o dashboard "Meta Ads" (Relatórios) chamando a Graph API ao vivo a
# cada request — igual o workflow n8n "Relatorio meta webhook" fazia — só
# que direto do backend, sem n8n. Ver Meta::AdsInsightsService.
#
# `serialize_row` porta a mesma transformação dos nós "Code"/"Code1-4" desse
# workflow (custo por mensagem/lead calculado a partir de `actions`), pro
# HTML do relatório (que já espera essas chaves em português) não precisar
# mudar quase nada além da URL chamada.
class Api::V1::Reports::MetaAdsController < Api::V1::BaseController
  ACTION_TYPES = {
    'onsite_conversion.messaging_conversation_started_7d' => :mensagens,
    'link_click' => :link_click,
    'offsite_conversion.fb_pixel_lead' => :leads_pixel,
    'lead' => :leads_ads
  }.freeze

  def insights
    conteudo = params[:conteudo].presence || 'geral'
    result = Meta::AdsInsightsService.new.campaign_insights(
      ad_account_id: params.require(:ad_account_id),
      conteudo: conteudo,
      date_start: params.require(:date_start),
      date_stop: params.require(:date_stop)
    )

    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    render json: Array(result.data).map { |row| serialize_row(row, conteudo) }
  end

  def campaigns
    result = Meta::AdsInsightsService.new.campaigns(ad_account_id: params.require(:ad_account_id))
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    render json: result.data
  end

  # Lista leve de contas (sem insights) pra popular o seletor no relatório —
  # substitui o campo de digitar o ID da conta manualmente. business_id
  # opcional escopa às contas de uma Business Manager específica.
  def accounts
    result = Meta::AdsInsightsService.new.ad_accounts(business_id: params[:business_id])
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    render json: Array(result.data).map { |a| { id: a['account_id'] || a['id'].to_s.delete_prefix('act_'), name: a['name'] } }
  end

  # Lista as Business Managers pro seletor "BM" acima do seletor de conta.
  def business_managers
    result = Meta::AdsInsightsService.new.business_managers
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway) unless result.success

    render json: result.data
  end

  private

  def serialize_row(row, conteudo)
    actions = tally_actions(row['actions'])
    spend = row['spend'].to_f
    impressions = row['impressions'].to_i
    reach = row['reach'].to_i

    custo = ->(valor) { valor.positive? ? format('%.2f', spend / valor).tr('.', ',') : '0,00' }

    base = {
      'Data' => row['date_start'],
      'Campanha' => row['campaign_name'],
      'Conjunto de Anúncios' => row['adset_name'],
      'Anúncio' => row['ad_name'],
      'Gasto' => format('%.2f', spend).tr('.', ','),
      'Mensagens' => actions[:mensagens],
      'Custo por Mensagens' => custo.call(actions[:mensagens]),
      'Cliques' => actions[:link_click],
      'CPC' => custo.call(actions[:link_click]),
      'Impressões' => impressions,
      'CPM' => impressions.positive? ? custo.call(impressions / 1000.0) : '0,00',
      'Alcance' => reach,
      'Frequência' => reach.positive? ? format('%.2f', impressions.to_f / reach).tr('.', ',') : '0,00',
      'Objetivo' => row['objective'],
      'Leads do Pixel' => actions[:leads_pixel],
      'Custo por Leads Pixel' => custo.call(actions[:leads_pixel]),
      'Leads do Meta Ads' => actions[:leads_ads],
      'Custo por Leads Ads' => custo.call(actions[:leads_ads])
    }

    base.merge(breakdown_fields(conteudo, row))
  end

  def breakdown_fields(conteudo, row)
    case conteudo
    when 'hora'
      { 'Hora (Audience TZ)' => row['hourly_stats_aggregated_by_audience_time_zone'] || 'N/A' }
    when 'idade_genero'
      { 'Idade' => row['age'] || 'N/A', 'Gênero' => row['gender'] || 'N/A' }
    when 'regiao'
      { 'Região' => row['region'] || 'N/A' }
    when 'posicionamento'
      {
        'Impression Device' => row['impression_device'] || 'N/A',
        'Device Platform' => row['device_platform'] || 'N/A',
        'Platform Position' => row['platform_position'] || 'N/A',
        'Publisher Platform' => row['publisher_platform'] || 'N/A'
      }
    else
      {}
    end
  end

  def tally_actions(actions)
    totals = { mensagens: 0, link_click: 0, leads_pixel: 0, leads_ads: 0 }
    Array(actions).each do |action|
      key = ACTION_TYPES[action['action_type']]
      totals[key] += action['value'].to_i if key
    end
    totals
  end
end
