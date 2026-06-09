# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Channel::Sendgrid, type: :model do
  let(:valid_attrs) do
    {
      api_key: 'SG.test-key-123',
      from_email: 'sender@example.com',
      from_name: 'Test Sender',
      sender_domain: 'example.com'
    }
  end

  let(:scopes_url) { 'https://api.sendgrid.com/v3/scopes' }
  let(:webhook_url) { 'https://api.sendgrid.com/v3/user/webhooks/event/settings' }

  before do
    stub_request(:get, scopes_url).to_return(status: 200, body: '{}')
    stub_request(:patch, webhook_url).to_return(status: 200, body: '{}')
  end

  describe 'api_key encryption at rest' do
    it 'persists the api_key encrypted, never in plaintext' do
      channel = described_class.create!(valid_attrs)

      expect(channel.api_key_encrypted).to be_present
      expect(channel.api_key_encrypted).not_to include('SG.test-key-123')
      expect(channel.api_key_encrypted).to start_with('gAAAAA')
    end

    it 'returns the original api_key through the getter after reload' do
      channel = described_class.create!(valid_attrs)

      expect(channel.reload.api_key).to eq('SG.test-key-123')
    end

    it 'clears the encrypted value when the api_key is set to blank' do
      channel = described_class.new(valid_attrs)
      channel.api_key = ''

      expect(channel.api_key_encrypted).to be_nil
    end

    it 're-encrypts when the api_key changes and drops the previous ciphertext' do
      channel = described_class.create!(valid_attrs)
      original_cipher = channel.api_key_encrypted

      channel.update!(api_key: 'SG.rotated-key')

      expect(channel.api_key_encrypted).not_to eq(original_cipher)
      expect(channel.reload.api_key).to eq('SG.rotated-key')
    end
  end

  describe 'validations' do
    it 'is valid with a full payload' do
      expect(described_class.new(valid_attrs)).to be_valid
    end

    it 'requires an api_key' do
      channel = described_class.new(valid_attrs.except(:api_key))

      expect(channel).not_to be_valid
      expect(channel.errors[:api_key]).to be_present
    end

    it 'requires a present, well-formed from_email' do
      expect(described_class.new(valid_attrs.merge(from_email: 'not-an-email'))).not_to be_valid
      expect(described_class.new(valid_attrs.merge(from_email: nil))).not_to be_valid
    end

    it 'rejects a malformed reply_to but allows blank' do
      expect(described_class.new(valid_attrs.merge(reply_to: 'nope'))).not_to be_valid
      expect(described_class.new(valid_attrs.merge(reply_to: ''))).to be_valid
    end

    it 'rejects a malformed sender_domain but allows blank' do
      expect(described_class.new(valid_attrs.merge(sender_domain: 'not a domain'))).not_to be_valid
      expect(described_class.new(valid_attrs.merge(sender_domain: ''))).to be_valid
    end
  end

  describe '#name' do
    it 'returns SendGrid' do
      expect(described_class.new.name).to eq('SendGrid')
    end
  end

  describe 'api key smoke test on save' do
    it 'persists and marks the webhook active when SendGrid accepts the key' do
      channel = described_class.create!(valid_attrs)

      expect(channel.reload.webhook_registration_status).to eq('active')
    end

    it 'raises and does not persist when SendGrid rejects the key' do
      stub_request(:get, scopes_url).to_return(status: 401, body: '{}')

      expect { described_class.create!(valid_attrs) }.to raise_error(Sendgrid::InvalidApiKeyError)
      expect(described_class.count).to eq(0)
    end

    it 'skips the smoke test and webhook when the api_key is unchanged' do
      channel = described_class.create!(valid_attrs)
      WebMock.reset_executed_requests!

      channel.update!(from_name: 'Renamed')

      expect(a_request(:get, scopes_url)).not_to have_been_made
      expect(a_request(:patch, webhook_url)).not_to have_been_made
    end

    it 're-runs the smoke test when the api_key is rotated' do
      channel = described_class.create!(valid_attrs)
      WebMock.reset_executed_requests!

      channel.update!(api_key: 'SG.rotated')

      expect(a_request(:get, scopes_url)).to have_been_made.once
    end
  end

  describe 'webhook registration failure' do
    it 'persists the channel and marks the webhook failed on a SendGrid 5xx' do
      stub_request(:patch, webhook_url).to_return(status: 500, body: 'oops')

      channel = described_class.create!(valid_attrs)

      expect(channel.reload.webhook_registration_status).to eq('failed')
    end

    it 'marks the webhook failed without calling SendGrid when no absolute callback URL is configured' do
      original = ENV.values_at('SENDGRID_WEBHOOK_URL', 'FRONTEND_URL')
      ENV.delete('SENDGRID_WEBHOOK_URL')
      ENV.delete('FRONTEND_URL')

      channel = described_class.create!(valid_attrs)

      expect(channel.reload.webhook_registration_status).to eq('failed')
      expect(a_request(:patch, webhook_url)).not_to have_been_made
    ensure
      ENV['SENDGRID_WEBHOOK_URL'] = original[0]
      ENV['FRONTEND_URL'] = original[1]
    end
  end
end
