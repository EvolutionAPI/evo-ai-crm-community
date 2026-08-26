# frozen_string_literal: true

# Maps Virtu checkout webhooks to the canonical lead shape. Field paths are
# resolved defensively over the common checkout-payload layouts (top-level,
# `data`, `customer`/`buyer` nesting) so a payload revision moves ONLY this
# file — the controller/service contract stays put.
module Webhooks
  module PurchaseAdapters
    class VirtuAdapter < Base
      # Statuses that mean "money confirmed". Anything else is acked and
      # ignored (refunds/chargebacks are out of scope for lead capture).
      APPROVED_STATUSES = %w[approved paid completed purchase_approved sale_approved].freeze

      def to_lead(payload)
        data = payload['data'].is_a?(Hash) ? payload['data'] : payload
        buyer = first_hash(data, %w[customer buyer client contact]) || data

        purchase_id = first_value(data, %w[purchase_id order_id transaction_id sale_id id])
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

      # Contact fields are only demanded for APPROVED events: a refund/
      # chargeback with a minimal payload must map cleanly so the service acks
      # it as ignored — a 4xx here would make the platform redeliver forever.
      def validate_mappable!(purchase_id, approved, email, phone)
        errors = []
        errors << { key: 'purchase_id', message: 'purchase id is required' } if purchase_id.blank?
        errors << { key: 'contact', message: 'email or phone_number is required' } if approved && email.blank? && phone.blank?
        raise MappingError.new(errors: errors) if errors.any?
      end

      def event_status(payload, data)
        (first_value(payload, %w[event status event_type type]) ||
          first_value(data, %w[status event]) || '').to_s
      end

      def first_hash(hash, keys)
        keys.map { |k| hash[k] }.find { |v| v.is_a?(Hash) }
      end

      def first_value(hash, keys)
        keys.map { |k| hash[k] }.find(&:present?)
      end

      # The checkout sends local BR numbers without the country code; prefix
      # +55 so the shared E.164 normalizer resolves them like the WhatsApp
      # inbound path does. Numbers already carrying a DDI pass through.
      def normalize_br_phone(raw)
        return nil if raw.blank?

        digits = raw.to_s.gsub(/\D/, '')
        return raw if raw.to_s.start_with?('+')
        return "+#{digits}" if digits.start_with?('55') && digits.length >= 12

        digits.length.between?(10, 11) ? "+55#{digits}" : "+#{digits}"
      end
    end
  end
end
