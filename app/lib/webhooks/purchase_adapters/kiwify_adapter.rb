# frozen_string_literal: true

# Maps Kiwify order events to the canonical lead shape. Layout per the public
# docs as of 2026-08-31: flat order fields (`order_id`, `order_status`,
# `webhook_event_type`) with PascalCase nests (`Customer`, `Product`,
# `Commissions`). Both casings are probed so a payload revision moves ONLY this
# file; pin them down once a real delivery fixture lands.
module Webhooks
  module PurchaseAdapters
    class KiwifyAdapter < Base
      APPROVED_EVENTS = %w[order_approved].freeze
      APPROVED_STATUSES = %w[paid approved].freeze

      def to_lead(payload)
        customer = first_hash(payload, %w[Customer customer]) || {}
        product = first_hash(payload, %w[Product product]) || {}
        commissions = first_hash(payload, %w[Commissions commissions]) || {}

        event = (payload['webhook_event_type'] || payload['order_status'] || '').to_s
        approved = APPROVED_EVENTS.include?(event.downcase) ||
                   APPROVED_STATUSES.include?(payload['order_status'].to_s.downcase)

        purchase_id = first_value(payload, %w[order_id order_ref])
        email = first_value(customer, %w[email])
        phone = first_value(customer, %w[mobile phone_number phone])

        validate_mappable!(purchase_id, approved, email, phone)

        {
          purchase_id: purchase_id.to_s,
          approved: approved,
          event: event,
          name: first_value(customer, %w[full_name name first_name]),
          email: email,
          phone_number: normalize_br_phone(phone),
          product: first_value(product, %w[product_name name]),
          amount: first_value(commissions, %w[charge_amount]) || first_value(payload, %w[amount total]),
          currency: first_value(commissions, %w[currency]) || 'BRL'
        }
      end
    end
  end
end
