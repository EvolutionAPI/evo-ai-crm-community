# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::Sendgrid, type: :model do
  let(:valid_attrs) do
    {
      api_key: 'SG.test-key-123',
      from_email: 'sender@example.com',
      from_name: 'Test Sender',
      sender_domain: 'example.com'
    }
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
end
