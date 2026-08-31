# frozen_string_literal: true

# Mints the URL to register at the payment platform. Hand-building it is a
# footgun: the `d` MAC pins evo_tenant/pipeline_id/product, which the platform's
# body signature cannot cover, and a wrong one fails closed with a 401.
# Delegates to Webhooks::PurchaseWebhookUrl — the same minter behind the
# pipeline screen — so host resolution and secret rules never drift.
namespace :evo_purchase_webhook do
  ABORTS = {
    unknown_provider: 'provider has no registered adapter',
    pipeline_not_found: 'pipeline_id does not match a pipeline',
    pipeline_without_stages: 'pipeline has no stages — the lead would have no entry stage',
    credential_missing: 'PURCHASE_WEBHOOK_SECRET_<PROVIDER> is not configured — the endpoint refuses every request until it is',
    destination_secret_required: 'PURCHASE_WEBHOOK_SECRET_DESTINATION is not configured — required for a ' \
                                 'public-credential platform: its key cannot sign the URL',
    host_not_configured: 'FRONTEND_URL is not configured — the URL would be relative and unregistrable'
  }.freeze

  desc 'Print the URL to register: evo_purchase_webhook:url[provider,evo_tenant,pipeline_id,product]'
  task :url, %i[provider evo_tenant pipeline_id product] => :environment do |_task, args|
    provider = args[:provider].to_s.downcase
    abort('usage: rake "evo_purchase_webhook:url[provider,evo_tenant,pipeline_id,product]"') if provider.blank?

    result = Webhooks::PurchaseWebhookUrl.new.mint(
      provider: provider,
      pipeline_id: args[:pipeline_id],
      product: args[:product].to_s.presence,
      evo_tenant: args[:evo_tenant].to_s.presence
    )

    abort("#{provider}: #{ABORTS.fetch(result.error, result.error.to_s)}") if result.error

    puts result.url
  end
end
