# frozen_string_literal: true

# Maps Cakto events to the canonical lead shape. Layout per the public docs as
# of 2026-08-31: `event` (e.g. purchase_approved) at the top level, order data
# under `data` with `customer`/`product` nests. The body-level `secret` field is
# authentication (PurchaseVerifiers::Cakto), never mapped. Field paths are
# resolved defensively so a payload revision moves ONLY this file; pin them down
# once a real delivery fixture lands.
module Webhooks
  module PurchaseAdapters
    class CaktoAdapter < Base
      APPROVED_EVENTS = %w[purchase_approved].freeze
      APPROVED_STATUSES = %w[paid approved].freeze
      PURCHASE_ID_KEYS = %w[ref_id refId order_id transaction_id id].freeze

      def to_lead(payload)
        data = hash_at(payload, 'data', payload)
        customer = first_hash(data, %w[customer buyer]) || data

        event = event_name(payload, data)
        approved = approved?(event, data['status'])
        purchase_id = first_value(data, PURCHASE_ID_KEYS)
        email = first_value(customer, %w[email])
        phone = first_value(customer, %w[phone phone_number cellphone])

        validate_mappable!(purchase_id, approved, email, phone)

        {
          purchase_id: purchase_id.to_s,
          approved: approved,
          event: event,
          name: first_value(customer, %w[name full_name]),
          email: email,
          phone_number: normalize_br_phone(phone),
          product: first_value(hash_at(data, 'product'), %w[name product_name]),
          amount: first_value(data, %w[amount value total base_amount]),
          currency: first_value(data, %w[currency]) || 'BRL'
        }
      end

      private

      def event_name(payload, data)
        (payload['event'] || data['status'] || '').to_s
      end

      def approved?(event, status)
        APPROVED_EVENTS.include?(event.downcase) || APPROVED_STATUSES.include?(status.to_s.downcase)
      end
    end
  end
end
