# frozen_string_literal: true

require 'rails_helper'
require 'evo_extension_points'

RSpec.describe 'EvoExtensionPoints :routing_strategy' do
  after { EvoExtensionPoints.reset! }

  it 'is declared in KNOWN_KEYS' do
    expect(EvoExtensionPoints::KNOWN_KEYS).to include(:routing_strategy)
  end

  it 'returns nil without override' do
    expect(EvoExtensionPoints.impl_for(:routing_strategy)).to be_nil
  end

  it 'is a Module under EvoExtensionPoints (satisfies contract_check guard-rail)' do
    expect(EvoExtensionPoints::RoutingStrategy).to be_a(Module)
  end

  describe 'with override' do
    let(:custom_strategy) { double('CustomStrategy') }

    before do
      EvoExtensionPoints.replace(:routing_strategy) do |_conversation, allowed_agent_ids:|
        custom_strategy
      end
    end

    it 'impl_for returns a callable Proc' do
      expect(EvoExtensionPoints.impl_for(:routing_strategy)).to respond_to(:call)
    end

    it 'the registered proc delegates to the custom impl' do
      impl = EvoExtensionPoints.impl_for(:routing_strategy)
      expect(impl.call(nil, allowed_agent_ids: [])).to eq(custom_strategy)
    end

    it 'impl_for returns nil after reset!' do
      EvoExtensionPoints.reset!
      expect(EvoExtensionPoints.impl_for(:routing_strategy)).to be_nil
    end
  end
end
