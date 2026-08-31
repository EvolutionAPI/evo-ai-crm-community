# frozen_string_literal: true

# Maps Hotmart (webhook 2.0) events to the canonical lead shape. Layout per the
# public docs as of 2026-08-31: `event` at the top level, order data under
# `data.purchase`, contact under `data.buyer`. Field paths are resolved
# defensively so a payload revision moves ONLY this file; pin them down once a
# real delivery fixture lands.
module Webhooks
  module PurchaseAdapters
    class HotmartAdapter < Base
      APPROVED_EVENTS = %w[PURCHASE_APPROVED PURCHASE_COMPLETE].freeze
      APPROVED_STATUSES = %w[APPROVED COMPLETE COMPLETED].freeze

      def to_lead(payload)
        data = payload['data'].is_a?(Hash) ? payload['data'] : payload
        purchase = data['purchase'].is_a?(Hash) ? data['purchase'] : data
        buyer = first_hash(data, %w[buyer customer]) || data
        product = data['product'].is_a?(Hash) ? data['product'] : {}

        event = (payload['event'] || purchase['status'] || '').to_s
        approved = APPROVED_EVENTS.include?(event.upcase) ||
                   APPROVED_STATUSES.include?(purchase['status'].to_s.upcase)

        purchase_id = first_value(purchase, %w[transaction order_ref order_id]) || payload['id']
        email = first_value(buyer, %w[email])
        phone = first_value(buyer, %w[checkout_phone phone])
        price = purchase['price'].is_a?(Hash) ? purchase['price'] : {}

        validate_mappable!(purchase_id, approved, email, phone)

        {
          purchase_id: purchase_id.to_s,
          approved: approved,
          event: event,
          name: first_value(buyer, %w[name full_name]),
          email: email,
          phone_number: normalize_br_phone(phone),
          product: first_value(product, %w[name product_name]) || first_value(data, %w[product_name]),
          amount: price['value'] || first_value(purchase, %w[amount value]),
          currency: first_value(price, %w[currency_value currency_code currency]) || 'BRL'
        }
      end
    end
  end
end
