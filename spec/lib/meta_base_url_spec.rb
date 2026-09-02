# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MetaBaseUrl do
  describe '.hub_url e .hub_frontend_url' do
    it 'usa o Hub central quando nao ha override' do
      expect(described_class.hub_url).to eq(described_class::HUB_API_URL)
      expect(described_class.hub_frontend_url).to eq(described_class::HUB_FRONTEND_URL)
    end

    it 'respeita o override de ambiente' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('EVOLUTION_HUB_API_URL').and_return('http://evolution-hub-backend:8086')
      allow(ENV).to receive(:[]).with('EVOLUTION_HUB_FRONTEND_URL').and_return('http://localhost:8050')

      expect(described_class.hub_url).to eq('http://evolution-hub-backend:8086')
      expect(described_class.hub_frontend_url).to eq('http://localhost:8050')
    end

    it 'ignora override em branco e cai no default' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('EVOLUTION_HUB_API_URL').and_return('')
      allow(ENV).to receive(:[]).with('EVOLUTION_HUB_FRONTEND_URL').and_return('  ')

      expect(described_class.hub_url).to eq(described_class::HUB_API_URL)
      expect(described_class.hub_frontend_url).to eq(described_class::HUB_FRONTEND_URL)
    end
  end
end
