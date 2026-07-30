# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_api_keys_table')

# The endpoint travels with the key it belongs to: a credential carrying its own
# base_url must decide both halves, or two credentials pointing at different
# gateways authenticate against whichever URL the installation happens to set.
RSpec.describe Ai::CredentialResolver, '.resolve_endpoint' do
  let(:fernet_key) { 'XoQPOBw2FrzjQS11utERG9qO2MsAnXFxlhIns_uUxRk=' }
  let(:go_ciphertext) do
    'gAAAAABqagvYo5FEA9quumGpPOgNwZMRVyKb5uFhsibgflYMUC5vdSCbbEdvdV4etg3_' \
      'CtQekqXPOtsIESs2aRluGJrCNy9rAxpiusgJdRoQ0EdVJIjsSdY='
  end
  let(:go_plaintext) { 'sk-proj-real-secret-4f2a' }

  # rubocop:disable RSpec/BeforeAfterAll -- DDL cannot run inside the per-example
  # transaction; shared helper so every spec agrees on the column set.
  before(:all) { EvoCoreApiKeysTable.create! }
  after(:all) { EvoCoreApiKeysTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  around do |example|
    original = ENV.fetch('EVO_AI_ENCRYPTION_KEY', nil)
    ENV['EVO_AI_ENCRYPTION_KEY'] = fernet_key
    example.run
    ENV['EVO_AI_ENCRYPTION_KEY'] = original
  end

  before { Ai::Credential.delete_all }

  def register(scope:, base_url: nil, provider: 'openai', active: true)
    Ai::Credential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: "cred-#{scope}-#{provider}-#{SecureRandom.hex(2)}",
        provider: provider,
        key: go_ciphertext,
        key_hint: '4f2a',
        scope: scope,
        base_url: base_url,
        is_active: active,
        created_at: Time.current,
        updated_at: Time.current
      }]
    )
  end

  it 'returns the endpoint stored with the credential' do
    register(scope: 'account', base_url: 'https://gateway.interno/v1')

    endpoint = described_class.resolve_endpoint(for_consumer: :inbox_assist)

    expect(endpoint.key).to eq(go_plaintext)
    expect(endpoint.base_url).to eq('https://gateway.interno/v1')
  end

  it 'returns nil for a credential with no endpoint of its own' do
    register(scope: 'account')

    expect(described_class.resolve_endpoint(for_consumer: :inbox_assist).base_url).to be_nil
  end

  # The half that was broken: the winning credential decides BOTH halves. An
  # account credential outranks the installation one, so its endpoint must come
  # with it instead of the installation one's.
  it 'takes the endpoint from the credential that won the chain' do
    register(scope: 'installation', base_url: 'https://casa.interno/v1')
    register(scope: 'account', base_url: 'https://conta.interno/v1')

    expect(described_class.resolve_endpoint(for_consumer: :inbox_assist).base_url)
      .to eq('https://conta.interno/v1')
  end

  it 'falls back to the installation endpoint when the account has none' do
    register(scope: 'installation', base_url: 'https://casa.interno/v1')

    expect(described_class.resolve_endpoint(for_consumer: :inbox_assist).base_url)
      .to eq('https://casa.interno/v1')
  end

  # A provider the consumer cannot speak is skipped for the key, so its endpoint
  # must not leak into the resolution either.
  it 'skips the endpoint of a credential the consumer cannot use' do
    register(scope: 'account', provider: 'anthropic', base_url: 'https://anthropic.interno')
    register(scope: 'installation', base_url: 'https://casa.interno/v1')

    expect(described_class.resolve_endpoint(for_consumer: :inbox_assist).base_url)
      .to eq('https://casa.interno/v1')
  end

  # The legacy sources carry a key and nothing else: the consumer's own
  # OPENAI_API_URL stays the endpoint there, as it always was.
  it 'reports no endpoint when the key came from the legacy fallback' do
    allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return('sk-legacy-global')

    endpoint = described_class.resolve_endpoint(for_consumer: :inbox_assist)

    expect(endpoint.key).to eq('sk-legacy-global')
    expect(endpoint.base_url).to be_nil
  end

  it 'keeps resolve_key answering exactly what resolve_endpoint carries' do
    register(scope: 'account', base_url: 'https://gateway.interno/v1')

    expect(described_class.resolve_key(for_consumer: :inbox_assist))
      .to eq(described_class.resolve_endpoint(for_consumer: :inbox_assist).key)
  end
end
