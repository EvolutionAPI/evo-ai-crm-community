# frozen_string_literal: true

# == Schema Information
#
# Table name: roles
#
#  id          :uuid             not null, primary key
#  description :text
#  key         :string           not null
#  name        :string           not null
#  system      :boolean          default(FALSE), not null
#  type        :string(10)       default("user"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_roles_on_key            (key) UNIQUE
#  index_roles_on_name           (name) UNIQUE
#  index_roles_on_type           (type)
#  index_roles_on_type_and_name  (type,name) UNIQUE
#
class Role < ApplicationRecord
  # Evolution Reference Model - managed by evo-auth-service
  # This model serves only as a reference to sync data from evo-auth-service

  self.table_name = 'roles'

  # The `roles` table has a `type` column (account/user) that is a DOMAIN
  # attribute — the scope of the role — NOT a Rails STI discriminator. Without
  # this line Rails treats `type` as the inheritance column and raises
  # ActiveRecord::SubclassNotFound ("subclass: 'user'") when instantiating any
  # role, breaking user.roles / Role.administrator_users / the Agents panel.
  # Same protection already used by Contact and Campaign (EVO-2128).
  self.inheritance_column = :_type_disabled

  # Read-only model - data is synced from evo-auth-service
  has_many :user_roles, dependent: :destroy_async
  has_many :users, through: :user_roles

  validates :key, presence: true, uniqueness: true
  validates :name, presence: true

  # Roles that count as administrative for CRM-side bypasses (inbox
  # visibility, audit log access, etc). `super_admin` is the installation
  # owner introduced by the auth-service rename — must be present here so
  # the bootstrap user keeps admin-level access in the CRM.
  ADMIN_ROLE_KEYS = %w[super_admin account_owner administrator admin].freeze

  # Check if this is an administrator role
  def administrator?
    key.in?(ADMIN_ROLE_KEYS)
  end

  # Find administrator role
  def self.administrator_role
    find_by(key: ADMIN_ROLE_KEYS)
  end

  # Find users with administrator roles
  def self.administrator_users
    Role.where(key: ADMIN_ROLE_KEYS).flat_map(&:users).uniq
  end
end
