# frozen_string_literal: true

# Public extension contract of evo-ai-crm-community. See EXTENSION_POINTS.md
# at the repository root for the full contract. The six sub-modules below
# ship no-op defaults; an external consumer overrides a specific extension
# point at process start via EvoExtensionPoints.replace(:name, &block) or via
# the per-module register* / replace* APIs.

require_relative 'evo_extension_points/capability_gate'
require_relative 'evo_extension_points/runtime_context'
require_relative 'evo_extension_points/plugin_loader'
require_relative 'evo_extension_points/theme_tokens'
require_relative 'evo_extension_points/data_export'
require_relative 'evo_extension_points/permission_resolver'
require_relative 'evo_extension_points/contract_check'

module EvoExtensionPoints
  EXTENSION_POINTS_VERSION = '2.1.0'

  KNOWN_KEYS = %i[
    capability_gate
    runtime_context_current_id
    runtime_context_with_scope
    theme_tokens
    permission_resolver
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
