# Preenche campaign/adset/ad name nos WhatsappAdLead pendentes via Graph API.
# Ver WhatsappAdLeads::EnrichmentService.

class WhatsappAdLeads::EnrichmentJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    WhatsappAdLeads::EnrichmentService.new.perform
  end
end
