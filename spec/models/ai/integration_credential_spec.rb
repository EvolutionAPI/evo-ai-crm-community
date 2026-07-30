# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/evo_core_integration_credentials_table')

# the CRM-side read-only view over the vault.
RSpec.describe Ai::IntegrationCredential do
  # rubocop:disable RSpec/BeforeAfterAll -- DDL cannot run inside the
  # per-example transaction.
  before(:all) { EvoCoreIntegrationCredentialsTable.create! }
  after(:all) { EvoCoreIntegrationCredentialsTable.drop! }
  # rubocop:enable RSpec/BeforeAfterAll

  before { described_class.delete_all }

  def register(name:, kind: 'static', scope: 'account', active: true, **extra)
    described_class.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: name, provider: 'dify', kind: kind, scope: scope,
        value: kind == 'static' ? 'ciphertext' : nil,
        value_hint: kind == 'static' ? '4f2a' : nil,
        is_active: active,
        created_at: Time.current, updated_at: Time.current
      }.merge(extra)]
    )
    described_class.find_by(name: name)
  end

  it 'is read-only — writes belong to the core service' do
    credential = register(name: 'Dify prod')

    expect(credential.readonly?).to be(true)
    expect { credential.update!(name: 'Outro') }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it 'distinguishes static from oauth rows' do
    static = register(name: 'Dify prod')
    oauth = register(name: 'GitHub conn', kind: 'oauth',
                     owner_store: 'agent_integration', owner_ref: 'abc')

    expect(static).to be_static
    expect(oauth).to be_oauth
    expect(described_class.static_kind).to contain_exactly(static)
    expect(described_class.oauth_kind).to contain_exactly(oauth)
  end

  it 'allows the same name in different scopes (UNIQUE is (scope, name))' do
    register(name: 'Producao', scope: 'account')

    expect { register(name: 'Producao', scope: 'installation') }.not_to raise_error
    expect { register(name: 'Producao', scope: 'account') }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'filters by activity and scope like the AI credential model' do
    active = register(name: 'Ativa')
    register(name: 'Inativa', active: false)

    expect(described_class.active).to contain_exactly(active)
    expect(described_class.for_scope('account')).to include(active)
  end

  # The spec helper must mirror the CHECKs the Go migration creates, or the
  # suite runs against a schema where "by construction" does not hold. These
  # fail if the helper drops them again.
  describe 'the CHECK constraints the Go migration creates' do
    it 'rejects an unknown kind' do
      expect { register(name: 'Invalida', kind: 'nonsense') }
        .to raise_error(ActiveRecord::StatementInvalid, /kind_check/)
    end

    # NOT 'agency': that one is deliberately allowed in the test helper, because
    # the FR2 guard specs insert it to prove the chain accepts a new link.
    it 'rejects an unknown scope' do
      expect { register(name: 'Invalida', scope: 'nonsense') }
        .to raise_error(ActiveRecord::StatementInvalid, /scope_check/)
    end

    it 'rejects a static row without a value' do
      expect { register(name: 'Sem valor', kind: 'static', value: nil) }
        .to raise_error(ActiveRecord::StatementInvalid, /kind_content_check/)
    end

    # The whole point of the oauth kind: no token value ever lands in the vault.
    it 'rejects an oauth row carrying a value' do
      expect do
        register(name: 'Com token', kind: 'oauth', value: 'ciphertext',
                 owner_store: 'agent_integration', owner_ref: 'abc')
      end.to raise_error(ActiveRecord::StatementInvalid, /kind_content_check/)
    end

    it 'rejects an oauth row without an owner reference' do
      expect { register(name: 'Sem dono', kind: 'oauth') }
        .to raise_error(ActiveRecord::StatementInvalid, /kind_content_check/)
    end
  end
end
