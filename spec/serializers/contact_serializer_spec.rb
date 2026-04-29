# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContactSerializer do
  describe '.serialize' do
    let(:created_at) { Time.zone.parse('2026-04-28 10:00:00') }

    def build_contact(avatar_url: '')
      contact = double(
        'Contact',
        as_json: {
          'id' => 1, 'name' => 'Jane Doe', 'type' => 'person',
          'email' => 'jane@example.com', 'phone_number' => '+5511999999999',
          'identifier' => nil, 'blocked' => false, 'availability_status' => 'online',
          'tax_id' => nil, 'website' => nil, 'industry' => nil
        },
        additional_attributes: {},
        custom_attributes: {},
        created_at: created_at,
        last_activity_at: nil,
        avatar_url: avatar_url,
        labels: []
      )
      allow(contact).to receive(:type).and_return('person')
      contact
    end

    it 'emits thumbnail field with avatar_url so the frontend ContactAvatar helper can render it (EVO-1012)' do
      contact = build_contact(avatar_url: 'https://example.com/uploads/avatar.jpg')

      result = described_class.serialize(contact, include_labels: false)

      expect(result).to have_key('thumbnail')
      expect(result['thumbnail']).to eq('https://example.com/uploads/avatar.jpg')
    end

    it 'returns empty thumbnail string when contact has no avatar attached' do
      contact = build_contact(avatar_url: '')

      result = described_class.serialize(contact, include_labels: false)

      expect(result['thumbnail']).to eq('')
    end
  end
end
