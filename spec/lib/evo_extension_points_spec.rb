# frozen_string_literal: true

require 'rails_helper'
require 'evo_extension_points'

RSpec.describe EvoExtensionPoints do
  # Always reset the top-level EvoExtensionPoints between examples, even when
  # nested describe blocks change described_class to a submodule that does not
  # implement reset!.
  after { EvoExtensionPoints.reset! } # rubocop:disable RSpec/DescribedClass

  describe '.replace' do
    it 'rejects unknown extension point keys' do
      expect { described_class.replace(:not_a_thing) { :noop } }
        .to raise_error(described_class::UnknownExtensionPoint)
    end

    it 'requires a block' do
      expect { described_class.replace(:feature_gate) }.to raise_error(ArgumentError)
    end
  end

  describe EvoExtensionPoints::FeatureGate do
    it 'returns true for any flag in the community default' do
      expect(described_class.feature_enabled?(:anything)).to be true
      expect(described_class.feature_enabled?(:paid_feature, account: 'x')).to be true
    end

    it 'honors a replace override' do
      EvoExtensionPoints.replace(:feature_gate) { |flag, **_ctx| flag == :paid_feature }
      expect(described_class.feature_enabled?(:paid_feature)).to be true
      expect(described_class.feature_enabled?(:other)).to be false
    end
  end

  describe EvoExtensionPoints::TenantContext do
    it 'returns nil for current_tenant_id in the community default' do
      expect(described_class.current_tenant_id).to be_nil
    end

    it 'passes through with_tenant yielding without binding state' do
      yielded = false
      result = described_class.with_tenant('any-id') do
        yielded = true
        :payload
      end
      expect(yielded).to be true
      expect(result).to eq(:payload)
      expect(described_class.current_tenant_id).to be_nil
    end

    it 'honors a replace override on current_tenant_id' do
      EvoExtensionPoints.replace(:tenant_context_current_id) { 'tenant-42' }
      expect(described_class.current_tenant_id).to eq('tenant-42')
    end
  end

  describe EvoExtensionPoints::PluginLoader do
    it 'returns an empty list of plugins by default' do
      expect(described_class.plugins).to eq([])
    end

    it 'load_all is a no-op when nothing is registered' do
      expect { described_class.load_all }.not_to raise_error
      expect(described_class.plugins).to eq([])
    end

    it 'records registered plugins and invokes on_boot callbacks' do
      booted = []
      described_class.register_plugin(:demo) do |plugin|
        plugin.on_boot { booted << :demo }
      end
      expect(described_class.plugins).to eq([:demo])
      described_class.load_all
      expect(booted).to eq([:demo])
    end
  end

  describe EvoExtensionPoints::ThemeTokens do
    it 'returns the canonical Evolution token set by default' do
      tokens = described_class.defaults
      expect(tokens).to include(
        '--evo-color-primary-500' => '#00ffa7',
        '--evo-color-background' => '#0b0f14'
      )
    end

    it 'returns a fresh copy so callers can mutate without poisoning the default' do
      first = described_class.defaults
      first['--evo-color-primary-500'] = '#000000'
      expect(described_class.defaults['--evo-color-primary-500']).to eq('#00ffa7')
    end

    it 'honors a replace override scoped by argument' do
      EvoExtensionPoints.replace(:theme_tokens) { |scope| { 'scope' => scope.to_s } }
      expect(described_class.defaults(scope: :consumer)).to eq('scope' => 'consumer')
    end
  end

  describe EvoExtensionPoints::DataExport do
    it 'returns an empty list by default (community registers nothing)' do
      expect(described_class.exportable_tables_for_tenant('any')).to eq([])
      expect(described_class.registered_names).to eq([])
    end

    it 'invokes registered scope blocks with the tenant id' do
      described_class.register(name: :widgets) { |tenant_id| ["widget-#{tenant_id}"] }
      result = described_class.exportable_tables_for_tenant('tenant-7')
      expect(result).to eq([{ name: :widgets, records: ['widget-tenant-7'] }])
    end

    it 'rejects registration without a scope block' do
      expect { described_class.register(name: :empty) }.to raise_error(ArgumentError)
    end
  end
end
