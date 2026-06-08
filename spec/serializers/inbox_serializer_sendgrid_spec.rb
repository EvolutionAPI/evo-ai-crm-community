# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InboxSerializer do
  describe '.serialize with a SendGrid channel' do
    let(:channel) do
      Channel::Sendgrid.create!(
        api_key: 'SG.secret-xyz',
        from_email: 'sender@example.com',
        from_name: 'Sender',
        sender_domain: 'example.com'
      )
    end
    let(:inbox) { Inbox.create!(channel: channel, name: 'SG Inbox') }

    it 'exposes safe sendgrid fields and signals api key presence' do
      result = described_class.serialize(inbox)

      expect(result['from_email']).to eq('sender@example.com')
      expect(result['api_key_present']).to be(true)
      expect(result).not_to have_key('api_key')
    end

    it 'never leaks the api key when the full channel is included' do
      result = described_class.serialize(inbox, include_channel: true)

      expect(result['channel']).not_to have_key('api_key_encrypted')
      expect(result['channel']).not_to have_key('api_key')
      expect(result.to_json).not_to include('SG.secret-xyz')
    end
  end
end
