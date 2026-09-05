# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ai::ScopeChain do
  # insert_link mutates module state; restore the seed after every example so a
  # 3-link chain does not leak into another test.
  after { described_class.reset! }

  describe '.chain' do
    it 'is the base seed by default' do
      expect(described_class.chain).to eq(%i[installation account])
    end

    it 'returns a frozen copy so a caller cannot mutate the chain' do
      expect(described_class.chain).to be_frozen
      expect { described_class.chain << :agency }.to raise_error(FrozenError)
      expect(described_class.chain).to eq(%i[installation account])
    end
  end

  describe '.insert_link' do
    it 'inserts a link immediately before the named one' do
      described_class.insert_link(:agency, before: :account)
      expect(described_class.chain).to eq(%i[installation agency account])
    end

    # A reloading boot hook re-runs the insert; without idempotency the chain
    # would grow agency, agency, agency unnoticed.
    it 'is idempotent — inserting the same link twice does not duplicate it' do
      described_class.insert_link(:agency, before: :account)
      described_class.insert_link(:agency, before: :account)
      expect(described_class.chain).to eq(%i[installation agency account])
    end

    it 'raises when the anchor link is unknown, never inserting silently' do
      expect { described_class.insert_link(:agency, before: :nope) }
        .to raise_error(ArgumentError, /unknown chain link/)
      expect(described_class.chain).to eq(%i[installation account])
    end
  end

  describe '.resolve' do
    it 'walks from the most specific link to the most generic' do
      seen = []
      described_class.resolve do |scope|
        seen << scope
        nil
      end
      expect(seen).to eq(%i[account installation])
    end

    it 'returns the first non-nil the block yields and stops there' do
      seen = []
      result = described_class.resolve do |scope|
        seen << scope
        scope == :account ? :hit : nil
      end
      expect(result).to eq(:hit)
      expect(seen).to eq(%i[account])
    end

    it 'walks an inserted link in precedence order' do
      described_class.insert_link(:agency, before: :account)
      seen = []
      described_class.resolve do |scope|
        seen << scope
        nil
      end
      expect(seen).to eq(%i[account agency installation])
    end
  end

  describe '.reset!' do
    it 'restores the base seed' do
      described_class.insert_link(:agency, before: :account)
      described_class.reset!
      expect(described_class.chain).to eq(%i[installation account])
    end
  end
end
