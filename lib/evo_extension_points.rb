# frozen_string_literal: true

# Public extension contract of evo-ai-crm-community. See EXTENSION_POINTS.md
# at the repository root for the full contract. The five sub-modules below
# ship no-op defaults; an external consumer overrides a specific extension
# point at process start via EvoExtensionPoints.replace(:name, &block) or via
# the per-module register* / replace* APIs.

require_relative 'evo_extension_points/feature_gate'
require_relative 'evo_extension_points/tenant_context'
require_relative 'evo_extension_points/plugin_loader'
require_relative 'evo_extension_points/theme_tokens'
require_relative 'evo_extension_points/data_export'

module EvoExtensionPoints
  KNOWN_KEYS = %i[
    feature_gate
    tenant_context_current_id
    tenant_context_with_tenant
    theme_tokens
  ].freeze

  class UnknownExtensionPoint < ArgumentError; end

  class << self
    def replace(key, &block)
      raise ArgumentError, 'block required' unless block
      raise UnknownExtensionPoint, "unknown extension point: #{key.inspect}" unless KNOWN_KEYS.include?(key)

      overrides[key] = block
      block
    end

    def impl_for(key)
      overrides[key]
    end

    def reset!
      @overrides = nil
      PluginLoader.reset!
      DataExport.reset!
    end

    private

    def overrides
      @overrides ||= {}
    end
  end
end
