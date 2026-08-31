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
      PURCHASE_ID_KEYS = %w[transaction order_ref order_id].freeze

      def to_lead(payload)
        data, purchase, buyer = sections(payload)

        event = event_name(payload, purchase)
        approved = approved?(event, purchase['status'])
        purchase_id = resolve_purchase_id('hotmart', first_value(purchase, PURCHASE_ID_KEYS), payload['id'])
        email = first_value(buyer, %w[email])
        phone = first_value(buyer, %w[checkout_phone phone])

        validate_mappable!(purchase_id, approved, email, phone)

        {
          purchase_id: purchase_id.to_s,
          approved: approved,
          event: event,
          name: first_value(buyer, %w[name full_name]),
          email: email,
          phone_number: normalize_br_phone(phone),
          product: first_value(hash_at(data, 'product'), %w[name product_name]) || first_value(data, %w[product_name]),
          amount: hash_at(purchase, 'price')['value'] || first_value(purchase, %w[amount value]),
          currency: first_value(hash_at(purchase, 'price'), %w[currency_value currency_code currency]) || 'BRL'
        }
      end

      private

      # An envelope-less delivery (or a revision that flattens it) still has to
      # map, so each section falls back to the level above it.
      def sections(payload)
        data = hash_at(payload, 'data', payload)
        purchase = hash_at(data, 'purchase', data)
        [data, purchase, first_hash(data, %w[buyer customer]) || data]
      end

      def event_name(payload, purchase)
        (payload['event'] || purchase['status'] || '').to_s
      end

      def approved?(event, status)
        APPROVED_EVENTS.include?(event.upcase) || APPROVED_STATUSES.include?(status.to_s.upcase)
      end
    end
  end
end
