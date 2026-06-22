# frozen_string_literal: true

# Conceptual contract for ERP adapters. Concrete adapters do NOT need to
# inherit from this — duck typing (`#to_bulk_params(payload)`) is enough.
# Base exists so the contract has one home for documentation and so that
# specs can assert the interface against a single anchor.
module Webhooks
  module ErpAdapters
    class Base
      # @param payload [Hash] parsed JSON body posted by the ERP
      # @return [Hash] canonical `{ products: Array<Hash> }`
      # @raise [Webhooks::ErpAdapters::MappingError] when payload is unmappable.
      #   The MappingError carries `errors:` as an array of
      #   `{ index:, raw_payload_key:, message: }` indexed by position in
      #   the original ERP payload (S3-AC4).
      def to_bulk_params(_payload)
        raise NotImplementedError, "#{self.class} must implement #to_bulk_params"
      end
    end
  end
end
