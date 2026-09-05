# frozen_string_literal: true

# Registers purchase webhook adapters at boot. `to_prepare` runs on every
# eager reload in development so the registry stays consistent across
# autoloads.
Rails.application.config.to_prepare do
  Webhooks::PurchaseAdapters.register(:virtu, Webhooks::PurchaseAdapters::VirtuAdapter)
  Webhooks::PurchaseAdapters.register(:hotmart, Webhooks::PurchaseAdapters::HotmartAdapter,
                                      verifier: Webhooks::PurchaseVerifiers::Hotmart)
  Webhooks::PurchaseAdapters.register(:kiwify, Webhooks::PurchaseAdapters::KiwifyAdapter,
                                      verifier: Webhooks::PurchaseVerifiers::Kiwify)
  Webhooks::PurchaseAdapters.register(:cakto, Webhooks::PurchaseAdapters::CaktoAdapter,
                                      verifier: Webhooks::PurchaseVerifiers::Cakto)
end
