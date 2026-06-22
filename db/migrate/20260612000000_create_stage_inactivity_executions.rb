class CreateStageInactivityExecutions < ActiveRecord::Migration[7.1]
  def change
    create_table :stage_inactivity_executions, id: :uuid do |t|
      t.uuid :pipeline_item_id, null: false
      t.uuid :pipeline_stage_id, null: false
      t.string :rule_id, null: false      # rule['id'] (uuid) ou hash estável de fallback
      t.string :base                       # 'no_customer_reply' ou 'stage_stagnation'
      t.string :action                     # send_ai_message / send_direct_message / send_template / finalize / ...
      t.datetime :executed_at, null: false
      t.jsonb :action_config, default: {}
      t.text :message_sent                 # mensagem enviada (nil enquanto reservado, antes do envio)

      t.timestamps
    end

    add_index :stage_inactivity_executions, :pipeline_item_id
    add_index :stage_inactivity_executions, :executed_at
    # Barra a SEGUNDA mensagem (reserva-antes-de-enviar): índice único por (item, regra).
    add_index :stage_inactivity_executions, %i[pipeline_item_id rule_id],
              unique: true, name: 'index_stage_inactivity_on_item_and_rule'

    add_foreign_key :stage_inactivity_executions, :pipeline_items, on_delete: :cascade
  end
end
