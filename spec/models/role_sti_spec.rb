# frozen_string_literal: true

require 'rails_helper'

# EVO-2128: the `roles` table has a `type` column (account/user) that is a DOMAIN
# attribute, not a Rails STI discriminator. Role must disable inheritance so that
# instantiating a role never raises ActiveRecord::SubclassNotFound.
RSpec.describe Role, type: :model do
  describe 'STI disabled' do
    it 'uses a disabled inheritance column (not the domain `type` column)' do
      expect(Role.inheritance_column).to eq('_type_disabled')
    end

    it 'loads roles without SubclassNotFound even when `type` is "user"' do
      skip 'roles table has no `type` column in this schema' unless Role.column_names.include?('type')

      role = Role.new(key: 'evo2128_test_role', name: 'EVO-2128 Test Role')
      role[:type] = 'user'
      role.save!(validate: false)

      expect { Role.where(id: role.id).to_a }.not_to raise_error
      expect(Role.find(role.id).read_attribute(:type)).to eq('user')
    ensure
      Role.where(key: 'evo2128_test_role').delete_all
    end
  end
end
