# frozen_string_literal: true

module EvoExtensionPoints
  # Data export extension point. The community release does not declare any
  # exportable tables on its own — DataExport.exportable_tables_for_tenant
  # returns []. An external consumer (e.g. an enterprise gem providing
  # tenant-scoped data export) registers exportable tables via
  # DataExport.register(name:, &scope_block) at boot, and the registry is
  # consulted at runtime.
  #
  # The "scope block" receives a tenant_id and must return an Enumerable of
  # records or a query-like object the caller can iterate. The community
  # never reaches into community tables on behalf of the consumer; the block
  # is the consumer's responsibility.
  module DataExport
    Entry = Struct.new(:name, :scope_block, keyword_init: true)

    class << self
      def register(name:, &scope_block)
        raise ArgumentError, 'scope_block is required' unless scope_block

        sym = name.to_sym
        registry[sym] = Entry.new(name: sym, scope_block: scope_block)
        sym
      end

      def exportable_tables_for_tenant(tenant_id)
        registry.values.map do |entry|
          { name: entry.name, records: entry.scope_block.call(tenant_id) }
        end
      end

      def registered_names
        registry.keys.dup
      end

      def reset!
        @registry = nil
      end

      private

      def registry
        @registry ||= {}
      end
    end
  end
end
