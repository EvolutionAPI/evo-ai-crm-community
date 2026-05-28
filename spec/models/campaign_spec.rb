# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Campaign, type: :model do
  let(:attrs) do
    {
      title: 'Black Friday',
      name: "campaign-#{SecureRandom.hex(4)}",
      type: 'Default'
    }
  end

  describe '.find_by(id:)' do
    it 'returns the active record by id and exposes #name' do
      campaign = described_class.create!(attrs)
      expect(described_class.find_by(id: campaign.id)&.name).to eq(attrs[:name])
    end
  end

  describe 'default_scope' do
    it 'excludes rows soft-deleted via deleted_at' do
      campaign = described_class.create!(attrs)
      campaign.update!(deleted_at: Time.current)
      expect(described_class.find_by(id: campaign.id)).to be_nil
      expect(described_class.unscoped.find_by(id: campaign.id)).to be_present
    end
  end
end
