# frozen_string_literal: true

# Registers purchase webhook adapters at boot. `to_prepare` runs on every
# eager reload in development so the registry stays consistent across
# autoloads.
Rails.application.config.to_prepare do
  Webhooks::PurchaseAdapters.register(:virtu, Webhooks::PurchaseAdapters::VirtuAdapter)
end
