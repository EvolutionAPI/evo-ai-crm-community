# frozen_string_literal: true

# Registers ERP webhook adapters at boot. `to_prepare` runs on every
# eager reload in development so the registry stays consistent across
# autoloads.
Rails.application.config.to_prepare do
  Webhooks::ErpAdapters.register(:noop, Webhooks::ErpAdapters::NoopAdapter)
end
