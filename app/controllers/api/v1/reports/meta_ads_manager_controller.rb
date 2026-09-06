# Substitui o webhook n8n do "Painel Tráfego" (gerenciador de campanhas Meta)
# por um único endpoint que despacha por `acao`, igual o Switch do n8n —
# de propósito, pra o HTML gigante em dashboards-src/painel_trafego.html
# precisar mudar só a URL que chama (webhookUrl), não a lógica inteira de
# 6+ formulários de edição que já existiam.
#
# ATENÇÃO: `editar`/`duplicar`/`criar_campanha` escrevem em anúncios/
# campanhas reais (gasto real se o status virar ACTIVE). `criar_campanha`
# não existia no n8n de referência (branch morta) — foi implementado do
# zero em Meta::AdsManagerService#create_campaign_full a partir do payload
# que o modal "Criar Campanha" do painel_trafego.html já montava.
class Api::V1::Reports::MetaAdsManagerController < Api::V1::BaseController
  def handle
    service = Meta::AdsManagerService.new

    case params[:acao]
    when 'lista_bms'
      respond(service.business_managers)
    when 'conta_de_anuncio', 'lista_de_contas'
      respond(service.ad_accounts(business_id: params[:id_bm]))
    when 'campanhas', 'adsets', 'ads'
      respond(service.campaigns_tree(
        ad_account_id: params.require(:id_conta_anuncio),
        date_start: params.require(:date_start),
        date_stop: params.require(:date_stop)
      ))
    when 'criativo'
      respond(service.creative_details(ad_id: params.require(:id_anuncio)))
    when 'editar'
      nivel = params.require(:nivel)
      edicao = filtered_edicao(nivel, parse_edicao(params[:edicao]))
      respond(service.update(id: params.require(:id), edicao: edicao))
    when 'duplicar'
      edicao = parse_edicao(params[:edicao])
      respond(service.duplicate_ad(id: params.require(:id), edicao: edicao))
    when 'criar_campanha'
      campanha = params[:campanha].is_a?(ActionController::Parameters) ? params[:campanha].to_unsafe_h : (params[:campanha] || {})
      respond(service.create_campaign_full(ad_account_id: params.require(:id_conta_anuncio), campanha: campanha))
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

  # O front monta `edicao` como uma string tipo `"status":"ACTIVE"` (sem
  # chaves externas) pra concatenar no corpo JSON que ia pro n8n — mantemos
  # o mesmo formato pra não precisar tocar nos 6 formulários de edição.
  def parse_edicao(raw)
    return {} if raw.blank?

    JSON.parse("{#{raw}}")
  rescue JSON::ParserError
    Rails.logger.error "Api::V1::Reports::MetaAdsManagerController: edicao inválida: #{raw.inspect}"
    {}
  end

  def filtered_edicao(nivel, edicao)
    allowed = Meta::AdsManagerService::EDITABLE_FIELDS[nivel] || []
    edicao.slice(*allowed)
  end
end
