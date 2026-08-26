# frozen_string_literal: true

# Mints the URL to register at the payment platform. Hand-building it is a
# footgun: the `d` MAC pins evo_tenant/pipeline_id/product, which the platform's
# body signature cannot cover, and a wrong one fails closed with a 401.
namespace :evo_purchase_webhook do
  desc 'Print the URL to register: evo_purchase_webhook:url[provider,evo_tenant,pipeline_id,product]'
  task :url, %i[provider evo_tenant pipeline_id product] => :environment do |_task, args|
    provider = args[:provider].to_s.downcase
    abort('usage: rake "evo_purchase_webhook:url[provider,evo_tenant,pipeline_id,product]"') if provider.blank?
    abort("provider '#{provider}' has no registered adapter") unless Webhooks::PurchaseAdapters.registered?(provider)

    config_key = "PURCHASE_WEBHOOK_SECRET_#{provider.upcase}"
    secret = GlobalConfigService.load(config_key, nil).to_s
    abort("#{config_key} is not configured — the endpoint refuses every request until it is") if secret.blank?

    values = Webhooks::PurchaseDestinationMac::PARAMS.index_with { |key| args[key.to_sym].to_s }
    query = values.reject { |_key, value| value.blank? }
    query[Webhooks::PurchaseDestinationMac::QUERY_PARAM] = Webhooks::PurchaseDestinationMac.mint(secret, provider, values)

    puts "#{ENV.fetch('FRONTEND_URL', '')}/api/v1/webhooks/purchases/#{provider}?#{query.to_query}"
  end
end
