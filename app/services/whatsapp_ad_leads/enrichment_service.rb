# WhatsappAdLeads::EnrichmentService - preenche campaign/adset/ad name nos
# WhatsappAdLead pendentes, buscando o `source_id` (ad id) na Graph API. Sem
# isso o lead só tem a prévia bruta do anúncio (headline/body/thumbnail),
# sem saber de qual campanha ele veio.
#
# Rodar sob demanda (ex: job periódico) — não é chamado no fluxo de
# recebimento da mensagem pra não atrasar a entrega da conversa.
class WhatsappAdLeads::EnrichmentService
  def initialize(meta_service: Meta::AdsInsightsService.new)
    @meta_service = meta_service
  end

  def perform(limit: 50)
    return unless @meta_service.connected?

    WhatsappAdLead.pending_enrichment.limit(limit).find_each do |lead|
      enrich(lead)
    end
  end

  private

  def enrich(lead)
    result = @meta_service.ad(lead.source_id)

    unless result.success
      Rails.logger.warn "WhatsappAdLeads::EnrichmentService: ad #{lead.source_id} lookup failed: #{result.error}"
      # Marca como enriquecido mesmo em falha (ex: anúncio deletado) pra não
      # tentar de novo pra sempre — o preview (headline/body) já capturado
      # continua valendo como fallback.
      lead.update!(enriched: true, enriched_at: Time.current)
      return
    end

    data = result.data
    lead.update!(
      ad_id: data['id'],
      ad_name: data['name'],
      adset_id: data.dig('adset', 'id'),
      adset_name: data.dig('adset', 'name'),
      campaign_id: data.dig('campaign', 'id'),
      campaign_name: data.dig('campaign', 'name'),
      enriched: true,
      enriched_at: Time.current
    )
  end
end
