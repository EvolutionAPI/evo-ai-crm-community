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
    end
  end
end
