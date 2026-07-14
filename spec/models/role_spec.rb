# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Role, type: :model do
  # EVO-2128: `roles.type` (account/user) is a domain attribute owned by
  # evo-auth-service, not a Rails STI discriminator. Role must disable
  # inheritance or loading any role raises ActiveRecord::SubclassNotFound.
  describe 'STI' do
    it 'disables inheritance so `type` stays a plain attribute' do
      expect(Role.inheritance_column).to eq('_type_disabled')
    end

    it 'loads a persisted role whose `type` is "user"' do
      skip 'roles has no `type` column in this schema' unless Role.column_names.include?('type')

      role = create(:role)
      role.update_column(:type, 'user')

      expect(Role.find(role.id).read_attribute(:type)).to eq('user')
    end
  end

  describe 'associations' do
    it { should have_many(:user_roles).dependent(:destroy_async) }
    it { should have_many(:users).through(:user_roles) }
  end

  describe 'validations' do
    it { should validate_presence_of(:key) }
    it { should validate_presence_of(:name) }
    it { should validate_uniqueness_of(:key) }
  end

  describe '.ADMIN_ROLE_KEYS' do
    it 'includes super_admin, account_owner, administrator, admin' do
      expect(Role::ADMIN_ROLE_KEYS).to match_array(%w[super_admin account_owner administrator admin])
    end
  end

  describe '#administrator?' do
    context 'when role key is in ADMIN_ROLE_KEYS' do
      it 'returns true for super_admin' do
        role = build(:role, key: 'super_admin')
        expect(role.administrator?).to be true
      end

      it 'returns true for administrator' do
        role = build(:role, key: 'administrator')
        expect(role.administrator?).to be true
      end

      it 'returns true for account_owner' do
        role = build(:role, key: 'account_owner')
        expect(role.administrator?).to be true
      end

      it 'returns true for admin' do
        role = build(:role, key: 'admin')
        expect(role.administrator?).to be true
      end
    end

    context 'when role key is not in ADMIN_ROLE_KEYS' do
      it 'returns false for agent role' do
        role = build(:role, key: 'agent')
        expect(role.administrator?).to be false
      end
    end
  end

  describe '.administrator_role' do
    let!(:admin_role) { create(:role, key: 'administrator') }
    let!(:agent_role) { create(:role, key: 'agent') }

    it 'returns first matching admin role' do
      expect(Role.administrator_role).to eq(admin_role)
    end
  end

  describe '.administrator_users' do
    let!(:admin_role) { create(:role, key: 'administrator') }
    let!(:super_admin_role) { create(:role, key: 'super_admin') }
    let!(:admin_user) { create(:user) }
    let!(:super_admin_user) { create(:user) }
    let!(:agent_user) { create(:user) }

    before do
      admin_user.roles << admin_role
      super_admin_user.roles << super_admin_role
      agent_user.roles << create(:role, key: 'agent')
    end

    it 'returns all users with admin roles' do
      expect(Role.administrator_users).to match_array([admin_user, super_admin_user])
    end

    it 'does not include agent users' do
      expect(Role.administrator_users).not_to include(agent_user)
    end
  end
end
