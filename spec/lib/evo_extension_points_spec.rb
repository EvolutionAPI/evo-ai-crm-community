# frozen_string_literal: true

require 'rails_helper'
require 'evo_extension_points'

RSpec.describe EvoExtensionPoints do
  after { EvoExtensionPoints.reset! } # rubocop:disable RSpec/DescribedClass

  describe 'EXTENSION_POINTS_VERSION' do
    it 'advertises the 2.1.0 contract' do
      expect(described_class::EXTENSION_POINTS_VERSION).to eq('2.1.0')
    end

    it 'includes :routing_strategy in KNOWN_KEYS' do
      expect(described_class::KNOWN_KEYS).to include(:routing_strategy)
    end

    it 'returns nil for :routing_strategy when no override is registered' do
      expect(described_class.impl_for(:routing_strategy)).to be_nil
    end
  end

  describe '.replace' do
    it 'rejects unknown extension point keys' do
      expect { described_class.replace(:not_a_thing) { :noop } }
        .to raise_error(described_class::UnknownExtensionPoint)
    end

    it 'requires a block' do
      expect { described_class.replace(:capability_gate) }.to raise_error(ArgumentError)
    end
  end

  describe EvoExtensionPoints::CapabilityGate do
    it 'returns true for any capability in the community default' do
      expect(described_class.enabled?(:anything)).to be true
      expect(described_class.enabled?(:flagship_capability, account: 'x')).to be true
    end

    it 'honors a replace override' do
      EvoExtensionPoints.replace(:capability_gate) { |name, **_ctx| name == :flagship_capability }
      expect(described_class.enabled?(:flagship_capability)).to be true
      expect(described_class.enabled?(:other)).to be false
    end
  end

  describe EvoExtensionPoints::RuntimeContext do
    it 'returns nil for current_scope_id in the community default' do
      expect(described_class.current_scope_id).to be_nil
    end

    it 'passes through with_scope yielding without binding state' do
      yielded = false
      result = described_class.with_scope('any-id') do
        yielded = true
        :payload
      end
      expect(yielded).to be true
      expect(result).to eq(:payload)
      expect(described_class.current_scope_id).to be_nil
    end

    it 'honors a replace override on current_scope_id' do
      EvoExtensionPoints.replace(:runtime_context_current_id) { 'scope-42' }
      expect(described_class.current_scope_id).to eq('scope-42')
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

    it 'draw_routes is a no-op when nothing is registered' do
      mapper = double('mapper')
      expect { described_class.draw_routes(mapper) }.not_to raise_error
    end

    it 'draw_routes invokes every plugin routes callback with the mapper' do
      mapper = double('mapper')
      received = []
      described_class.register_plugin(:demo) do |plugin|
        plugin.routes { |m| received << m }
      end
      described_class.draw_routes(mapper)
      expect(received).to eq([mapper])
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
      expect(described_class.exportable_tables_for_scope('any')).to eq([])
      expect(described_class.registered_names).to eq([])
    end

    it 'invokes registered scope blocks with the scope id' do
      described_class.register(name: :widgets) { |scope_id| ["widget-#{scope_id}"] }
      result = described_class.exportable_tables_for_scope('scope-7')
      expect(result).to eq([{ name: :widgets, records: ['widget-scope-7'] }])
    end

    it 'rejects registration without a scope block' do
      expect { described_class.register(name: :empty) }.to raise_error(ArgumentError)
    end
  end
end
