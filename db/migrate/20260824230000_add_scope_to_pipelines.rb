# frozen_string_literal: true

class AddScopeToPipelines < ActiveRecord::Migration[7.1]
  def change
    # Default 'empresa' so every existing pipeline keeps showing under the
    # "Empresa" submenu without a backfill — only new pipelines can pick
    # 'pessoal' at creation time.
    add_column :pipelines, :scope, :string, default: 'empresa', null: false, if_not_exists: true
  end
end
