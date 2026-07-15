# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EvoExtensionPoints::PermissionResolver do
  after { EvoExtensionPoints.reset! }

  describe 'default implementation (community parity)' do
    it 'delegates to EvoAuthService#check_user_permission with the same arguments' do
      service = instance_double(EvoAuthService)
      allow(EvoAuthService).to receive(:new).and_return(service)
      expect(service).to receive(:check_user_permission).with('user-1', 'conversations.read').and_return(true)

      expect(described_class.allowed?(user_id: 'user-1', permission_key: 'conversations.read')).to be(true)
    end

    it 'returns the deny verdict untouched' do
      service = instance_double(EvoAuthService, check_user_permission: false)
      allow(EvoAuthService).to receive(:new).and_return(service)

      expect(described_class.allowed?(user_id: 'user-1', permission_key: 'contacts.delete')).to be(false)
    end

    it 'ignores extra context keys (scope_id is nil in community)' do
      service = instance_double(EvoAuthService, check_user_permission: true)
      allow(EvoAuthService).to receive(:new).and_return(service)

      expect(described_class.allowed?(user_id: 'u', permission_key: 'k', scope_id: nil)).to be(true)
    end

    it 'is registered as no override in a pure community install' do
      expect(EvoExtensionPoints.impl_for(:permission_resolver)).to be_nil
    end
  end

  describe 'consumer override' do
    it 'receives the full keyword context and its verdict is authoritative' do
      seen = nil
      EvoExtensionPoints.replace(:permission_resolver) do |user_id:, permission_key:, **ctx|
        seen = [user_id, permission_key, ctx]
        false
      end

      expect(described_class.allowed?(user_id: 'u1', permission_key: 'brand.manage', scope_id: 't1')).to be(false)
      expect(seen).to eq(['u1', 'brand.manage', { scope_id: 't1' }])
    end

    it 'stops applying after reset! (no leak between examples)' do
      EvoExtensionPoints.replace(:permission_resolver) { |**| false }
      EvoExtensionPoints.reset!

      service = instance_double(EvoAuthService, check_user_permission: true)
      allow(EvoAuthService).to receive(:new).and_return(service)

      expect(described_class.allowed?(user_id: 'u', permission_key: 'k')).to be(true)
    end
  end
end
