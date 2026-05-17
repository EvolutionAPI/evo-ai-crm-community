# frozen_string_literal: true

# Internal CI fixture. Exercises every EvoExtensionPoints extension point
# with a trivial counter/spy implementation. If a documented extension
# point is renamed or removed, one of the `replace` / `register` calls
# below raises EvoExtensionPoints::UnknownExtensionPoint or NameError and
# the suite fails immediately — that is the desired behaviour.
#
# Loaded only when BUNDLE_WITH=enterprise_stub is set during bundle
# install (Gemfile group :enterprise_stub).

require 'evo_extension_points'

module EnterpriseStub
  module Counters
    class << self
      def reset!
        @calls = Hash.new(0)
      end

      def increment(name)
        @calls ||= Hash.new(0)
        @calls[name] += 1
      end

      def calls
        @calls ||= Hash.new(0)
        @calls.dup
      end
    end
  end

  module Boot
    class << self
      def install! # rubocop:disable Metrics/MethodLength
        EvoExtensionPoints.replace(:feature_gate) do |flag, **_context|
          EnterpriseStub::Counters.increment(:feature_gate)
          flag != :explicitly_disabled
        end

        EvoExtensionPoints.replace(:tenant_context_current_id) do
          EnterpriseStub::Counters.increment(:tenant_context_current_id)
          'stub-tenant'
        end

        EvoExtensionPoints.replace(:tenant_context_with_tenant) do |_id, &block|
          EnterpriseStub::Counters.increment(:tenant_context_with_tenant)
          block&.call
        end

        EvoExtensionPoints.replace(:theme_tokens) do |scope|
          EnterpriseStub::Counters.increment(:theme_tokens)
          { 'stub-scope' => scope.to_s }
        end

        EvoExtensionPoints::PluginLoader.register_plugin(:enterprise_stub) do |plugin|
          plugin.on_boot { EnterpriseStub::Counters.increment(:plugin_loader_on_boot) }
        end

        EvoExtensionPoints::DataExport.register(name: :enterprise_stub_table) do |tenant_id|
          EnterpriseStub::Counters.increment(:data_export)
          [{ tenant_id: tenant_id, row: 'stub' }]
        end
      end
    end
  end
end

# One-shot: requiring this file installs the stubs into the global
# EvoExtensionPoints registry. Re-requiring is harmless (replace just
# overwrites the same keys), but resetting EvoExtensionPoints during a
# test will drop the stubs — re-call EnterpriseStub::Boot.install! to
# restore them.
EnterpriseStub::Boot.install!
