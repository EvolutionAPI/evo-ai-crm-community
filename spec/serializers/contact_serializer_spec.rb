# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContactSerializer do
  describe '.serialize' do
    let(:contact) { Contact.create!(name: 'Jane Doe', email: "jane-#{SecureRandom.hex(4)}@example.com") }

    it 'emits thumbnail with the contact avatar URL when present (EVO-1012)' do
      allow(contact).to receive(:avatar_url).and_return('https://cdn.example.com/uploads/avatar.jpg')

      result = described_class.serialize(contact, include_labels: false)

      expect(result).to have_key('thumbnail')
      expect(result['thumbnail']).to eq('https://cdn.example.com/uploads/avatar.jpg')
    end

    it 'returns nil thumbnail (not empty string) so the FE skips rendering <img src="">' do
      allow(contact).to receive(:avatar_url).and_return('')

      result = described_class.serialize(contact, include_labels: false)

      expect(result).to have_key('thumbnail')
      expect(result['thumbnail']).to be_nil
    end

    it 'returns nil thumbnail when contact has no avatar attached (real Avatarable path)' do
      result = described_class.serialize(contact, include_labels: false)

      expect(result).to have_key('thumbnail')
      expect(result['thumbnail']).to be_nil
    end
  end
end
