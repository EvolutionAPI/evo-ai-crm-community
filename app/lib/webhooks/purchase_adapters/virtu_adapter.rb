# frozen_string_literal: true

# Maps Virtu checkout webhooks to the canonical lead shape. Field paths are
# resolved defensively over the common checkout layouts (top-level, `data`,
# `customer`/`buyer` nesting) so a payload revision moves ONLY this file.
module Webhooks
  module PurchaseAdapters
    class VirtuAdapter < Base
      # Statuses that mean "money confirmed". Anything else is acked and ignored.
      APPROVED_STATUSES = %w[approved paid completed purchase_approved sale_approved].freeze
      PURCHASE_ID_KEYS = %w[purchase_id order_id transaction_id sale_id].freeze

      def to_lead(payload)
        data = payload['data'].is_a?(Hash) ? payload['data'] : payload
        buyer = first_hash(data, %w[customer buyer client contact]) || data

        purchase_id = resolve_purchase_id(data)
        email = first_value(buyer, %w[email])
        phone = first_value(buyer, %w[phone_number phone whatsapp cellphone mobile])

        status = event_status(payload, data)
        approved = APPROVED_STATUSES.include?(status.downcase)

        validate_mappable!(purchase_id, approved, email, phone)

        {
          purchase_id: purchase_id.to_s,
          approved: approved,
          event: status,
          name: first_value(buyer, %w[name full_name]),
          email: email,
          phone_number: normalize_br_phone(phone),
          product: first_value(data, %w[product product_name offer offer_name]),
          amount: first_value(data, %w[amount value total price]),
          currency: first_value(data, %w[currency]) || 'BRL'
        }
      end

      private

      # `id` is the last resort and a loud one: on platforms where it is the
      # per-DELIVERY event id (not the order id) every redelivery would mint a
      # second card. Pin a real order-id key once the provider fixture lands.
      def resolve_purchase_id(data)
        explicit = first_value(data, PURCHASE_ID_KEYS)
        return explicit if explicit.present?

        fallback = data['id']
        if fallback.present?
          Rails.logger.warn('Purchase webhook (virtu): no order-id field; falling back to the generic `id` — ' \
                            'idempotency breaks if that is a per-delivery event id')
        end
        fallback
      end

      def event_status(payload, data)
        (first_value(payload, %w[event status event_type type]) ||
          first_value(data, %w[status event]) || '').to_s
      end

    end
  end
end
