# frozen_string_literal: true

require 'rails_helper'

# The per-request permission cache must key on (user, scope, permission):
# the same user touching two scopes in one process may get different verdicts
# and must never be served the other scope's cached answer.
RSpec.describe EvoPermissionConcern do
  let(:harness_class) do
    Class.new do
      include EvoPermissionConcern
    end
  end

  let(:harness) { harness_class.new }

  before { Current.evo_permission_cache = nil }

  after do
    EvoExtensionPoints.reset!
    Current.reset
  end

  it 'keeps verdicts of different scopes apart and caches per scope' do
    calls = []
    EvoExtensionPoints.replace(:permission_resolver) do |user_id:, permission_key:, scope_id: nil, **|
      calls << [user_id, permission_key, scope_id]
      scope_id == 'scope-a'
    end

    allow(EvoExtensionPoints::RuntimeContext).to receive(:current_scope_id).and_return('scope-a')
    expect(harness.send(:has_user_permission?, 'u1', 'content.manage')).to be(true)

    allow(EvoExtensionPoints::RuntimeContext).to receive(:current_scope_id).and_return('scope-b')
    expect(harness.send(:has_user_permission?, 'u1', 'content.manage')).to be(false)

    # Back to scope-a: served from cache, resolver not called a third time.
    allow(EvoExtensionPoints::RuntimeContext).to receive(:current_scope_id).and_return('scope-a')
    expect(harness.send(:has_user_permission?, 'u1', 'content.manage')).to be(true)
    expect(calls.size).to eq(2)
  end

  it 'produces the community-equivalent key when no scope is bound (nil)' do
    # Explicit nil: the CI lane also runs under the consumer stub, which
    # registers a runtime_context override — without this stub the key would
    # carry the stub's scope and the example would be order-dependent.
    allow(EvoExtensionPoints::RuntimeContext).to receive(:current_scope_id).and_return(nil)
    service = instance_double(EvoAuthService, check_user_permission: true)
    allow(EvoAuthService).to receive(:new).and_return(service)

    expect(harness.send(:has_user_permission?, 'u1', 'contacts.read')).to be(true)
    expect(Current.evo_permission_cache).to have_key('user:u1::contacts.read')
  end

  it 'stays fail-closed when the resolver raises' do
    EvoExtensionPoints.replace(:permission_resolver) { |**| raise 'boom' }

    expect(harness.send(:has_user_permission?, 'u1', 'contacts.read')).to be(false)
  end
end
