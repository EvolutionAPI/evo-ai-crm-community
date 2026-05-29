# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutoAssignment::Strategies::FallbackChain do
  let(:conversation)  { double('Conversation', id: 42) }
  let(:agent)         { double('User') }
  let(:agent_ids)     { [1, 2, 3] }

  let(:succeeding_strategy) do
    strat = double('SucceedingStrategy')
    allow(strat).to receive(:call).and_return(agent)
    strat
  end

  let(:nil_strategy) do
    strat = double('NilStrategy')
    allow(strat).to receive(:call).and_return(nil)
    strat
  end

  let(:raising_strategy) do
    strat = double('RaisingStrategy')
    allow(strat).to receive(:call).and_raise(StandardError, 'boom')
    strat.define_singleton_method(:to_s) { 'RaisingStrategy' }
    strat
  end

  describe '.call' do
    context 'when the first strategy returns a User' do
      it 'returns that User without trying subsequent strategies' do
        expect(nil_strategy).not_to receive(:call)
        result = described_class.call(conversation, allowed_agent_ids: agent_ids,
                                      chain: [succeeding_strategy, nil_strategy])
        expect(result).to eq(agent)
      end
    end

    context 'when the first strategy returns nil' do
      it 'falls through to the next strategy' do
        result = described_class.call(conversation, allowed_agent_ids: agent_ids,
                                      chain: [nil_strategy, succeeding_strategy])
        expect(result).to eq(agent)
      end
    end

    context 'when a strategy raises an exception' do
      it 'logs the error and continues to the next strategy' do
        expect(Rails.logger).to receive(:error)
          .with(/\[FallbackChain\] strategy.*raised: boom/)
        result = described_class.call(conversation, allowed_agent_ids: agent_ids,
                                      chain: [raising_strategy, succeeding_strategy])
        expect(result).to eq(agent)
      end

      it 'does not propagate the exception' do
        allow(Rails.logger).to receive(:error)
        expect do
          described_class.call(conversation, allowed_agent_ids: agent_ids,
                               chain: [raising_strategy, nil_strategy])
        end.not_to raise_error
      end
    end

    context 'when all strategies return nil' do
      it 'returns nil' do
        result = described_class.call(conversation, allowed_agent_ids: agent_ids,
                                      chain: [nil_strategy, nil_strategy])
        expect(result).to be_nil
      end
    end

    context 'when all strategies raise exceptions' do
      it 'returns nil and logs each error' do
        allow(Rails.logger).to receive(:error)
        result = described_class.call(conversation, allowed_agent_ids: agent_ids,
                                      chain: [raising_strategy, raising_strategy])
        expect(result).to be_nil
      end
    end

    context 'when chain is empty' do
      it 'returns nil immediately' do
        result = described_class.call(conversation, allowed_agent_ids: agent_ids, chain: [])
        expect(result).to be_nil
      end
    end

    context 'when allowed_agent_ids is passed through to each strategy' do
      it 'forwards allowed_agent_ids unchanged' do
        strategy = double('Strategy')
        expect(strategy).to receive(:call)
          .with(conversation, allowed_agent_ids: agent_ids)
          .and_return(agent)
        described_class.call(conversation, allowed_agent_ids: agent_ids, chain: [strategy])
      end
    end
  end
end
