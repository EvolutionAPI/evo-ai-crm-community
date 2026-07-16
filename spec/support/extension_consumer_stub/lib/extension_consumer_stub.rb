# frozen_string_literal: true

# Internal CI fixture. Exercises every EvoExtensionPoints extension point
# with a trivial counter/spy implementation. If a documented extension
# point is renamed or removed, one of the `replace` / `register` calls
# below raises EvoExtensionPoints::UnknownExtensionPoint or NameError and
# the suite fails immediately — that is the desired behaviour.
#
# Loaded only when BUNDLE_WITH=extension_consumer_stub is set during bundle
# install (Gemfile group :extension_consumer_stub).

require 'evo_extension_points'

module ExtensionConsumerStub
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
        EvoExtensionPoints.replace(:capability_gate) do |name, **_context|
          ExtensionConsumerStub::Counters.increment(:capability_gate)
          name != :explicitly_disabled
        end

        EvoExtensionPoints.replace(:runtime_context_current_id) do
          ExtensionConsumerStub::Counters.increment(:runtime_context_current_id)
          'stub-scope'
        end

        EvoExtensionPoints.replace(:runtime_context_with_scope) do |_id, &block|
          ExtensionConsumerStub::Counters.increment(:runtime_context_with_scope)
          block&.call
        end

        EvoExtensionPoints.replace(:theme_tokens) do |scope|
          ExtensionConsumerStub::Counters.increment(:theme_tokens)
          { 'stub-scope' => scope.to_s }
        end

        # `user_id:` / `scope_id:` are swallowed by the anonymous `**`: the stub
        # only needs to prove the seam reaches a consumer and honours its verdict.
        EvoExtensionPoints.replace(:permission_resolver) do |permission_key:, **|
          ExtensionConsumerStub::Counters.increment(:permission_resolver)
          permission_key != 'explicitly.denied'
        end

        EvoExtensionPoints::PluginLoader.register_plugin(:extension_consumer_stub) do |plugin|
          plugin.on_boot { ExtensionConsumerStub::Counters.increment(:plugin_loader_on_boot) }
        end

        EvoExtensionPoints::DataExport.register(name: :extension_consumer_stub_table) do |scope_id|
          ExtensionConsumerStub::Counters.increment(:data_export)
          [{ scope_id: scope_id, row: 'stub' }]
        end
      end
    end
  end
end

# One-shot: requiring this file installs the stubs into the global
# EvoExtensionPoints registry. Re-requiring is harmless (replace just
# overwrites the same keys), but resetting EvoExtensionPoints during a
# test will drop the stubs — re-call ExtensionConsumerStub::Boot.install!
# to restore them.
#
# The contract guarantee lives in this very call, not in any example: an
# extension point that is renamed or removed makes a `replace` / `register`
# above raise here, at require time, before a single spec runs. Specs are
# therefore free to reset the registry to exercise the defaults; do NOT add a
# global hook re-installing the stub after each example, as the suite asserts
# default behaviour ("... by default") and would fail.
ExtensionConsumerStub::Boot.install!
