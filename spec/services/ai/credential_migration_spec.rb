# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_api_keys_table')

# EVO-2250 story 1.5 — the migration exists to NOT change which key is in use.
RSpec.describe Ai::CredentialMigration do
  let(:fernet_key) { 'XoQPOBw2FrzjQS11utERG9qO2MsAnXFxlhIns_uUxRk=' }
  let(:silent_logger) { Logger.new(File::NULL) }

  # rubocop:disable RSpec/BeforeAfterAll -- creating the table is DDL, which
  # cannot run inside the per-example transaction. Shared helper so every spec
  # agrees on the column set.
  before(:all) { EvoCoreApiKeysTable.create! }
  after(:all) { EvoCoreApiKeysTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  around do |example|
    original = ENV.fetch('EVO_AI_ENCRYPTION_KEY', nil)
    ENV['EVO_AI_ENCRYPTION_KEY'] = fernet_key
    example.run
    ENV['EVO_AI_ENCRYPTION_KEY'] = original
  end

  before do
    Ai::Credential.delete_all
    allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return(nil)
    allow(GlobalConfigService).to receive(:load).with('OPENAI_API_URL', nil).and_return(nil)
    allow(Integrations::Hook).to receive(:where).with(app_id: 'openai').and_return([])
    allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(nil)
  end

  def with_global_key(key, api_url: nil)
    allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', nil).and_return(key)
    allow(GlobalConfigService).to receive(:load).with('OPENAI_API_URL', nil).and_return(api_url)
  end

  def with_hook(key, id: SecureRandom.uuid)
    hook = instance_double(Integrations::Hook, id: id, enabled?: true,
                                               settings: { 'api_key' => key })
    allow(Integrations::Hook).to receive(:where).with(app_id: 'openai').and_return([hook])
    allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(hook)
    hook
  end

  def run(apply: false)
    described_class.call(apply: apply, logger: silent_logger)
  end

  describe 'dry run writes nothing (AC7)' do
    it 'reports without creating credentials' do
      with_global_key('sk-global-1111')

      expect { run(apply: false) }.not_to change(Ai::Credential, :count).from(0)
    end
  end

  describe 'installation level (AC1)' do
    it 'imports the global key as an installation credential' do
      with_global_key('sk-global-1111')
      run(apply: true)

      credential = Ai::Credential.find_by(scope: 'installation')
      expect(credential).to be_present
      expect(credential.name).to eq(described_class::INSTALLATION_NAME)
      expect(Ai::CredentialDecryptor.decrypt(credential.key)).to eq('sk-global-1111')
      expect(credential.key_hint).to eq('1111')
    end

    it 'marks a custom base URL as a non-stock provider' do
      with_global_key('sk-global-1111', api_url: 'https://llm.interno.example/v1')
      run(apply: true)

      expect(Ai::Credential.find_by(scope: 'installation').provider).to eq('custom_openai_compatible')
    end

    it 'keeps stock OpenAI when the URL points at api.openai.com' do
      with_global_key('sk-global-1111', api_url: 'https://api.openai.com/v1')
      run(apply: true)

      expect(Ai::Credential.find_by(scope: 'installation').provider).to eq('openai')
    end
  end

  describe 'account level (AC2)' do
    it 'imports the hook key as an account credential when there is no global key' do
      with_hook('sk-hook-2222')
      run(apply: true)

      credential = Ai::Credential.find_by(scope: 'account')
      expect(Ai::CredentialDecryptor.decrypt(credential.key)).to eq('sk-hook-2222')
    end
  end

  # The heart of the story: the precedence inverts, so a naive per-level import
  # would swap the key in use.
  describe 'both sources present — the winner must not change (AC3, NFR1)' do
    before { with_global_key('sk-global-1111') }

    it 'gives the account credential the GLOBAL value, not the hook one' do
      with_hook('sk-hook-2222')
      run(apply: true)

      account = Ai::Credential.active.find_by(scope: 'account')
      # Naively importing hook → account would make 'sk-hook-2222' win, which is
      # ignored today. That is the bug this story exists to prevent.
      expect(Ai::CredentialDecryptor.decrypt(account.key)).to eq('sk-global-1111')
    end

    it 'keeps the hook key as an inactive credential instead of discarding it' do
      with_hook('sk-hook-2222')
      run(apply: true)

      inactive = Ai::Credential.where(is_active: false).first
      expect(inactive).to be_present
      expect(Ai::CredentialDecryptor.decrypt(inactive.key)).to eq('sk-hook-2222')
    end

    it 'records the promotion in the report' do
      with_hook('sk-hook-2222')
      rows = run(apply: false)

      expect(rows.map(&:origin)).to include(/promovida para o escopo conta/)
    end

    it 'resolves to the same key after the migration as before it' do
      hook = with_hook('sk-hook-2222')
      before_key = Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist, legacy_hook: hook)
      run(apply: true)
      after_key = Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist, legacy_hook: hook)

      expect(after_key).to eq(before_key)
      expect(after_key).to eq('sk-global-1111')
    end

    it 'does not create a redundant inactive row when both values are equal' do
      with_hook('sk-global-1111')
      run(apply: true)

      expect(Ai::Credential.where(is_active: false).count).to eq(0)
    end
  end

  describe 'nothing configured (AC5)' do
    it 'finishes without writing and without raising' do
      expect { run(apply: true) }.not_to raise_error
      expect(Ai::Credential.count).to eq(0)
    end
  end

  describe 'idempotency (AC4)' do
    it 'creates nothing new on a second run' do
      with_global_key('sk-global-1111')
      with_hook('sk-hook-2222')
      run(apply: true)
      count_after_first = Ai::Credential.count

      run(apply: true)

      expect(Ai::Credential.count).to eq(count_after_first)
    end

    it 'does not revert a human rename' do
      with_global_key('sk-global-1111')
      run(apply: true)
      Ai::Credential.where(scope: 'installation')
                    .update_all(name: 'Renomeada pelo admin') # rubocop:disable Rails/SkipsModelValidations

      run(apply: true)

      credential = Ai::Credential.find_by(imported_from: described_class::INSTALLATION_SOURCE)
      expect(credential.name).to eq('Renomeada pelo admin')
    end

    it 'refuses to re-run after a human disabled the imported credential' do
      with_global_key('sk-global-1111')
      run(apply: true)
      Ai::Credential.where(scope: 'installation')
                    .update_all(is_active: false) # rubocop:disable Rails/SkipsModelValidations

      # Disabling it DID change the effective credential, so the gate is right
      # to refuse: re-running must not quietly paper over a human decision.
      expect { run(apply: true) }.to raise_error(described_class::AbortedError)
      expect(Ai::Credential.find_by(imported_from: described_class::INSTALLATION_SOURCE).is_active).to be(false)
    end
  end

  describe 'the report is a gate, not a log (AC7)' do
    it 'aborts instead of applying when a row would diverge' do
      with_global_key('sk-global-1111')
      # Artificial divergence: AFTER resolves to something else entirely.
      allow_any_instance_of(described_class).to receive(:effective_after).and_return('sk-outra-9999') # rubocop:disable RSpec/AnyInstance

      expect { run(apply: true) }.to raise_error(described_class::AbortedError, /would change effective credential/)
      expect(Ai::Credential.count).to eq(0)
    end

    it 'refuses to run without the encryption key' do
      ENV['EVO_AI_ENCRYPTION_KEY'] = nil
      with_global_key('sk-global-1111')

      # Writing unreadable credentials would only surface later, inside a job.
      expect { run(apply: true) }.to raise_error(described_class::AbortedError, /is not set/)
      expect(Ai::Credential.count).to eq(0)
    end
  end

  describe 'deterministic naming (AC6)' do
    it 'suffixes on collision instead of violating the UNIQUE index' do
      Ai::Credential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
        [{ name: described_class::INSTALLATION_NAME, provider: 'openai', key: 'x',
           key_hint: 'x', scope: 'account', is_active: false,
           created_at: Time.current, updated_at: Time.current }]
      )
      with_global_key('sk-global-1111')

      expect { run(apply: true) }.not_to raise_error
      expect(Ai::Credential.exists?(name: "#{described_class::INSTALLATION_NAME} (2)")).to be(true)
    end
  end

  describe 'legacy sources are preserved (story 1.6 removes them)' do
    it 'never deletes the global config nor the hook settings' do
      hook = with_hook('sk-hook-2222')
      with_global_key('sk-global-1111')

      expect(hook).not_to receive(:update)
      expect(hook).not_to receive(:destroy)

      run(apply: true)
      expect(hook.settings['api_key']).to eq('sk-hook-2222')
    end
  end
end
