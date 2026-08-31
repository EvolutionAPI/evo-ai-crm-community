# frozen_string_literal: true

# The purchase-adapter contract. Inheriting is optional (duck typing is enough);
# Base exists so the canonical lead shape has one home.
module Webhooks
  module PurchaseAdapters
    class Base
      # @param payload [Hash] parsed JSON body posted by the payment platform
      # @return [Hash] canonical lead shape:
      #   {
      #     purchase_id: String (required — the platform's order/transaction id),
      #     approved: Boolean (only approved purchases become leads),
      #     event: String (raw event name, for logs),
      #     name: String or nil,
      #     email: String or nil,
      #     phone_number: String or nil (raw; the service normalizes to E.164),
      #     product: String or nil,
      #     amount: Numeric or nil,
      #     currency: String or nil
      #   }
      #   email OR phone_number must be present — a lead with neither is
      #   unmappable.
      # @raise [Webhooks::PurchaseAdapters::MappingError] when unmappable.
      def to_lead(_payload)
        raise NotImplementedError, "#{self.class} must implement #to_lead"
      end

      protected

      # Contact fields are only demanded for APPROVED events: a refund with a
      # minimal payload must map cleanly so the service acks it as ignored — a
      # 4xx here would make the platform redeliver forever.
      def validate_mappable!(purchase_id, approved, email, phone)
        errors = []
        errors << { key: 'purchase_id', message: 'purchase id is required' } if purchase_id.blank?
        errors << { key: 'contact', message: 'email or phone_number is required' } if approved && email.blank? && phone.blank?
        raise MappingError.new(errors: errors) if errors.any?
      end

      # The generic `id` is a last resort and a loud one: where it is the
      # per-DELIVERY event id (Hotmart's top-level `id`) instead of the order id,
      # every redelivery mints a second card. Pin a real order-id key once a
      # provider fixture lands.
      def resolve_purchase_id(provider, explicit, generic_id)
        return explicit if explicit.present?

        if generic_id.present?
          Rails.logger.warn("Purchase webhook (#{provider}): no order-id field; falling back to the generic `id` — " \
                            'idempotency breaks if that is a per-delivery event id')
        end
        generic_id
      end

      # One nested section, or `fallback` when the key is absent or not a Hash.
      def hash_at(hash, key, fallback = {})
        hash[key].is_a?(Hash) ? hash[key] : fallback
      end

      def first_hash(hash, keys)
        keys.map { |k| hash[k] }.find { |v| v.is_a?(Hash) }
      end

      def first_value(hash, keys)
        keys.map { |k| hash[k] }.find(&:present?)
      end

      # BR checkouts often send local numbers without the country code; prefix
      # +55 so the shared E.164 normalizer resolves them like the WhatsApp
      # inbound path does. Anything of an implausible length is handed over
      # untouched — minting "+123" out of a truncated number only hides the
      # problem.
      def normalize_br_phone(raw)
        return nil if raw.blank?
        return raw if raw.to_s.start_with?('+')

        digits = raw.to_s.gsub(/\D/, '')
        return "+#{digits}" if digits.start_with?('55') && digits.length >= 12
        return "+55#{digits}" if digits.length.between?(10, 11)

        raw
      end
    end
  end
end
