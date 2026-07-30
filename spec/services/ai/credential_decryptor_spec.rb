# frozen_string_literal: true

require 'rails_helper'

# These ciphertexts were produced by the GO side (github.com/fernet/fernet-go),
# the service that owns the encryption, using the key below. They are frozen
# fixtures on purpose: they prove cross-language compatibility, which a
# Ruby-encrypted fixture could never do.
RSpec.describe Ai::CredentialDecryptor do
  # Same default as EVO_AI_ENCRYPTION_KEY in docker-compose.ecosystem.yml.
  let(:fernet_key) { 'XoQPOBw2FrzjQS11utERG9qO2MsAnXFxlhIns_uUxRk=' }

  # Encrypted by Go with the key above.
  let(:go_ciphertext) do
    'gAAAAABqagvYo5FEA9quumGpPOgNwZMRVyKb5uFhsibgflYMUC5vdSCbbEdvdV4etg3_' \
      'CtQekqXPOtsIESs2aRluGJrCNy9rAxpiusgJdRoQ0EdVJIjsSdY='
  end
  let(:go_plaintext) { 'sk-proj-real-secret-4f2a' }

  # Same, but with a timestamp 25 hours in the past. The Ruby gem enforces a
  # 60-second TTL by default while Go verifies with ttl=0, so this token is the
  # regression guard: without enforce_ttl=false every credential older than a
  # minute stops decrypting, in a job, silently.
  let(:go_old_ciphertext) do
    'gAAAAABqaKxgdFGfOo82ClGYuQ6QNxXDFUEpYc7PuCyssn42tgUcPXg-ruxzyWrO4zgc' \
      '6TNbUpo_1HcufS_dZQRU3aGCRuMOulnCh6fTCCcLRnj5B_RCK58='
  end
  let(:go_old_plaintext) { 'sk-proj-old-secret-91bc' }

  around do |example|
    original = ENV.fetch('EVO_AI_ENCRYPTION_KEY', nil)
    ENV['EVO_AI_ENCRYPTION_KEY'] = fernet_key
    example.run
    ENV['EVO_AI_ENCRYPTION_KEY'] = original
  end

  it 'decrypts a credential encrypted by the Go service' do
    expect(described_class.decrypt(go_ciphertext)).to eq(go_plaintext)
  end

  it 'decrypts a credential older than the gem default TTL' do
    # Fails with the gem's default 60s TTL. Remove enforce_ttl=false and this
    # is the example that catches it.
    expect(described_class.decrypt(go_old_ciphertext)).to eq(go_old_plaintext)
  end

  it 'returns nil for a blank value instead of raising' do
    expect(described_class.decrypt(nil)).to be_nil
    expect(described_class.decrypt('')).to be_nil
  end

  it 'returns nil for a tampered token' do
    expect(described_class.decrypt("#{go_ciphertext}tampered")).to be_nil
  end

  it 'returns nil for a token encrypted with another key' do
    other_key = Base64.urlsafe_encode64(OpenSSL::Random.random_bytes(32))
    token = Fernet.generate(other_key, 'sk-other')

    expect(described_class.decrypt(token)).to be_nil
  end

  it 'returns nil, without raising, when the key is not configured' do
    ENV['EVO_AI_ENCRYPTION_KEY'] = nil

    expect { described_class.decrypt(go_ciphertext) }.not_to raise_error
    expect(described_class.decrypt(go_ciphertext)).to be_nil
  end

  it 'does not read the InstallationConfig encryption key' do
    # ENV['ENCRYPTION_KEY'] holds a different secret; reading it here would
    # decrypt nothing and tempt someone to overwrite the installation key.
    expect(described_class::ENCRYPTION_KEY_ENV).to eq('EVO_AI_ENCRYPTION_KEY')
  end
end
