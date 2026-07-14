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

      role = Role.create!(key: 'evo2128_role', name: 'EVO-2128 Role')
      role.update_column(:type, 'user')

      expect(Role.find(role.id).read_attribute(:type)).to eq('user')
    end
  end

  describe 'associations' do
    it 'has many user_roles, destroyed async with the role' do
      association = Role.reflect_on_association(:user_roles)

      expect(association.macro).to eq(:has_many)
      expect(association.options[:dependent]).to eq(:destroy_async)
    end

    it 'has many users through user_roles' do
      association = Role.reflect_on_association(:users)

      expect(association.macro).to eq(:has_many)
      expect(association.options[:through]).to eq(:user_roles)
    end
  end

  describe 'validations' do
    it 'requires key and name' do
      role = Role.new

      expect(role).not_to be_valid
      expect(role.errors[:key]).to be_present
      expect(role.errors[:name]).to be_present
    end

    it 'requires key to be unique' do
      Role.create!(key: 'duplicated_key', name: 'First')
      duplicate = Role.new(key: 'duplicated_key', name: 'Second')

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:key]).to be_present
    end
  end

  describe '.ADMIN_ROLE_KEYS' do
    it 'includes super_admin, account_owner, administrator, admin' do
      expect(Role::ADMIN_ROLE_KEYS).to match_array(%w[super_admin account_owner administrator admin])
    end
  end

  describe '#administrator?' do
    it 'is true for every admin role key' do
      Role::ADMIN_ROLE_KEYS.each do |key|
        expect(Role.new(key: key, name: key)).to be_administrator
      end
    end

    it 'is false for the agent role' do
      expect(Role.new(key: 'agent', name: 'Agent')).not_to be_administrator
    end
  end

  describe '.administrator_role' do
    it 'returns the matching admin role' do
      admin_role = Role.create!(key: 'administrator', name: 'Administrator')
      Role.create!(key: 'agent', name: 'Agent')

      expect(Role.administrator_role).to eq(admin_role)
    end
  end

  describe '.administrator_users' do
    it 'returns the users carrying an admin role, and no one else' do
      admin_role = Role.create!(key: 'administrator', name: 'Administrator')
      super_admin_role = Role.create!(key: 'super_admin', name: 'Super Admin')
      agent_role = Role.create!(key: 'agent', name: 'Agent')

      admin_user = User.create!(email: 'evo2128-admin@example.com', name: 'Admin User')
      super_admin_user = User.create!(email: 'evo2128-super@example.com', name: 'Super Admin User')
      agent_user = User.create!(email: 'evo2128-agent@example.com', name: 'Agent User')

      admin_user.roles << admin_role
      super_admin_user.roles << super_admin_role
      agent_user.roles << agent_role

      expect(Role.administrator_users).to match_array([admin_user, super_admin_user])
      expect(Role.administrator_users).not_to include(agent_user)
    end
  end
end
