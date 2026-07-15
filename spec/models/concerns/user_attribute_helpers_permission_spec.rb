# frozen_string_literal: true

require 'rails_helper'

# User#has_permission? stopped being an unconditional `true` (story RBAC 4.2):
# it now resolves through the PermissionResolver seam, which re-arms every
# Pundit policy built on `administrator? || has_permission?(...)`.
RSpec.describe UserAttributeHelpers, type: :model do
  # Sem FactoryBot no repo: has_permission? só consulta #id — um User em
  # memória com uuid basta (o mirror não exige persistência para isto).
  let(:user) { User.new(id: SecureRandom.uuid) }

  after do
    EvoExtensionPoints.reset!
    Current.reset
  end

  describe '#has_permission?' do
    it 'grants when the resolver grants' do
      EvoExtensionPoints.replace(:permission_resolver) do |permission_key:, **|
        permission_key == 'conversations.read'
      end

      expect(user.has_permission?('conversations.read')).to be(true)
    end

    it 'denies when the resolver denies (no more unconditional true)' do
      EvoExtensionPoints.replace(:permission_resolver) { |**| false }

      expect(user.has_permission?('conversations.delete')).to be(false)
    end

    it 'delegates to the auth-service by default with the user id' do
      service = instance_double(EvoAuthService)
      allow(EvoAuthService).to receive(:new).and_return(service)
      expect(service).to receive(:check_user_permission).with(user.id, 'contacts.read').and_return(true)

      expect(user.has_permission?('contacts.read')).to be(true)
    end

    it 'reuses the per-request cache across repeated checks' do
      calls = 0
      EvoExtensionPoints.replace(:permission_resolver) do |**|
        calls += 1
        true
      end

      2.times { expect(user.has_permission?('contacts.read')).to be(true) }
      expect(calls).to eq(1)
    end

    it 'stays fail-closed when the resolver raises' do
      EvoExtensionPoints.replace(:permission_resolver) { |**| raise 'boom' }

      expect(user.has_permission?('contacts.read')).to be(false)
    end

    it 're-arms the Pundit policies built on it' do
      EvoExtensionPoints.replace(:permission_resolver) { |**| false }
      agent = User.new(id: SecureRandom.uuid)
      allow(agent).to receive(:administrator?).and_return(false)
      context = { user: agent, account: nil, service_authenticated: false }

      expect(ConversationPolicy.new(context, nil).index?).to be(false)
    end
  end
end
