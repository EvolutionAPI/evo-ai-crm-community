# frozen_string_literal: true

require 'rails_helper'

# EVO-2250 story 1.5.
#
# The migration writes credentials from Ruby that the Go core and the Python
# processor must read. Story 1.3 proved Go → Ruby; this proves the direction the
# migration actually depends on.
RSpec.describe Ai::CredentialEncryptor do
  let(:fernet_key) { 'XoQPOBw2FrzjQS11utERG9qO2MsAnXFxlhIns_uUxRk=' }

  around do |example|
    original = ENV.fetch('EVO_AI_ENCRYPTION_KEY', nil)
    ENV['EVO_AI_ENCRYPTION_KEY'] = fernet_key
    example.run
    ENV['EVO_AI_ENCRYPTION_KEY'] = original
  end

  describe '.encrypt' do
    it 'produces a token this codebase can read back' do
      token = described_class.encrypt('sk-migrated-secret-7c3d')

      expect(Ai::CredentialDecryptor.decrypt(token)).to eq('sk-migrated-secret-7c3d')
    end

    # The Go handler verifies with ttl=0 and the Fernet spec is byte-compatible
    # across implementations. This asserts the token SHAPE the Go side requires:
    # version byte 0x80, urlsafe base64. A token failing this would be written by
    # the migration and rejected by every consumer.
    it 'emits a spec-compliant Fernet token (version 0x80, urlsafe base64)' do
      token = described_class.encrypt('sk-migrated-secret-7c3d')
      raw = Base64.urlsafe_decode64(token)

      expect(raw.bytes.first).to eq(0x80)
      expect(token).to match(/\A[A-Za-z0-9_-]+=*\z/)
      # 1 version + 8 timestamp + 16 IV + ciphertext + 32 HMAC
      expect(raw.bytesize).to be > 57
    end

    it 'produces a different token each time for the same plaintext' do
      # Fernet embeds a random IV; identical ciphertexts would signal a broken
      # implementation, not a cache.
      first = described_class.encrypt('sk-same-secret')
      second = described_class.encrypt('sk-same-secret')

      expect(first).not_to eq(second)
      expect(Ai::CredentialDecryptor.decrypt(first)).to eq('sk-same-secret')
      expect(Ai::CredentialDecryptor.decrypt(second)).to eq('sk-same-secret')
    end

    it 'returns nil for blank input' do
      expect(described_class.encrypt(nil)).to be_nil
      expect(described_class.encrypt('')).to be_nil
    end

    it 'returns nil, without raising, when the key is not configured' do
      ENV['EVO_AI_ENCRYPTION_KEY'] = nil

      expect { described_class.encrypt('sk-whatever') }.not_to raise_error
      expect(described_class.encrypt('sk-whatever')).to be_nil
    end
  end

  describe '.key_hint' do
    it 'takes the last four characters, like the Go DeriveKeyHint' do
      expect(described_class.key_hint('sk-proj-abcdef1234f2a')).to eq('4f2a')
      expect(described_class.key_hint('ab12')).to eq('ab12')
      expect(described_class.key_hint('ab')).to eq('ab')
      expect(described_class.key_hint('')).to eq('')
      expect(described_class.key_hint(nil)).to eq('')
    end

    it 'counts characters, not bytes' do
      expect(described_class.key_hint('sk-chave-ção')).to eq('-ção')
    end
  end
end
