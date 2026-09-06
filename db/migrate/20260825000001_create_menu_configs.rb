# frozen_string_literal: true

class CreateMenuConfigs < ActiveRecord::Migration[7.1]
  def change
    create_table :menu_configs, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :scope, null: false
      t.jsonb :payload, null: false, default: {}
      t.timestamps
    end

    add_index :menu_configs, [:user_id, :scope], unique: true, name: 'index_menu_configs_on_user_and_scope'
  end
end
