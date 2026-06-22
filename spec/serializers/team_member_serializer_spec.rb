# frozen_string_literal: true

require 'rails_helper'

# Defense-in-depth for the orphaned-team-member fix (T0.2): even if a nil slips
# into the collection, serialize_collection must never emit a null entry.
RSpec.describe TeamMemberSerializer do
  let(:user) { User.create!(email: "tm-#{SecureRandom.hex(4)}@example.com", name: 'Valid User') }

  describe '.serialize_collection' do
    it 'drops nil entries and returns only serialized valid users' do
      result = described_class.serialize_collection([user, nil])

      expect(result).to be_an(Array)
      expect(result).not_to include(nil)
      expect(result.length).to eq(1)
      expect(result.first[:id]).to eq(user.id)
    end

    it 'returns an empty array when the collection is entirely nil entries' do
      expect(described_class.serialize_collection([nil, nil])).to eq([])
    end

    it 'returns an empty array when given nil' do
      expect(described_class.serialize_collection(nil)).to eq([])
    end
  end

  describe '.serialize' do
    it 'returns nil for a nil user (defense in depth)' do
      expect(described_class.serialize(nil)).to be_nil
    end
  end
end
