# Serve o dashboard "Leads Dashboard" (Relatórios) a partir dos dados
# capturados de verdade no WhatsApp (WhatsappAdLead), sem passar pelo n8n —
# ver Whatsapp::EvolutionHandlers::ContentHandlers#handle_ad_referral.
class Api::V1::Reports::WhatsappAdLeadsController < Api::V1::BaseController
  # Devolve um array puro (não {data: [...]}) — o HTML do relatório checa
  # Array.isArray(result) direto na resposta, igual fazia com o n8n.
  def index
    leads = WhatsappAdLead.includes(:contact)
    leads = leads.where(platform: params[:platform]) if params[:platform].present?
    leads = leads.where(status: params[:status]) if params[:status].present?
    leads = leads.where(campaign_id: params[:campaign_id]) if params[:campaign_id].present?
    leads = leads.where(created_at: parse_date(params[:date_start])..parse_date(params[:date_stop], end_of_day: true)) if params[:date_start].present?
    leads = leads.order(created_at: :desc).limit(2000)

    render json: leads.map { |lead| serialize(lead) }
  end

  def update
    lead = WhatsappAdLead.find(params[:id])
    lead.update!(lead_params)
    render json: { data: serialize(lead) }
  rescue ActiveRecord::RecordNotFound
    error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Lead não encontrado.', status: :not_found)
  end

  private

  def lead_params
    params.permit(:status, :valor_venda)
  end

  def parse_date(value, end_of_day: false)
    date = Time.zone.parse(value.to_s)
    end_of_day ? date.end_of_day : date.beginning_of_day
  rescue ArgumentError
    end_of_day ? Time.zone.now.end_of_day : 100.years.ago
  end

  # Chaves batem com a tabela de leads hardcoded no HTML do relatório
  # (mesmos nomes que a tabela de referência whatsapp_anuncio usava) — as que
  # esse fork ainda não captura (endereço, CPF, pedido, etc.) ficam de fora
  # e a coluna aparece em branco, não é um bug.
  def serialize(lead)
    {
      id: lead.id,
      telefone: lead.contact&.phone_number,
      nome: lead.contact&.name,
      email: lead.contact&.email,
      data_criacao: lead.created_at,
      plataforma: lead.platform,
      campaign_id: lead.campaign_id,
      campaign_name: lead.campaign_name,
      adset_name: lead.adset_name,
      ad_name: lead.ad_name,
      Anuncio_title: lead.headline,
      Anuncio_body: lead.body,
      Anuncio_thumbnail_url: lead.thumbnail_url,
      ctwaclid: lead.ctwaclid,
      gclid: lead.gclid,
      utm_source: lead.utm_source,
      utm_medium: lead.utm_medium,
      utm_campaign: lead.utm_campaign,
      utm_term: lead.utm_term,
      utm_content: lead.utm_content,
      status: lead.status,
      valor_venda: lead.valor_venda,
      enriched: lead.enriched
    }
  end
end
