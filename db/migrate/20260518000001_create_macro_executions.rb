class CreateMacroExecutions < ActiveRecord::Migration[7.0]
  def change
    create_table :macro_executions, id: :uuid do |t|
      t.references :macro, type: :uuid, null: false, foreign_key: true
      t.references :conversation, type: :uuid, null: false, foreign_key: true
      t.references :user, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.integer :status, default: 0, null: false
      t.text :error_message
      t.jsonb :actions_result, default: []
      t.datetime :completed_at

      t.timestamps
    end

    add_index :macro_executions, [:conversation_id, :created_at]
    add_index :macro_executions, :status
  end
end
