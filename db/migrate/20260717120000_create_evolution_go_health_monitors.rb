class CreateEvolutionGoHealthMonitors < ActiveRecord::Migration[7.1]
  def change
    create_table :evolution_go_health_monitors, id: :uuid, if_not_exists: true do |t|
      t.references :observed_channel, type: :uuid, null: false,
                   foreign_key: { to_table: :channel_whatsapp, on_delete: :cascade }
      t.references :notification_channel, type: :uuid, null: false,
                   foreign_key: { to_table: :channel_whatsapp, on_delete: :cascade }
      t.string :recipient_number, null: false
      t.boolean :enabled, null: false, default: true
      t.integer :failure_threshold, null: false, default: 2
      t.integer :recovery_threshold, null: false, default: 1
      t.integer :cooldown_minutes, null: false, default: 30
      t.string :last_state, null: false, default: 'unknown'
      t.integer :consecutive_failures, null: false, default: 0
      t.integer :consecutive_successes, null: false, default: 0
      t.datetime :last_checked_at
      t.datetime :last_alerted_at
      t.text :last_error
      t.timestamps
    end

    add_index :evolution_go_health_monitors, :observed_channel_id,
              unique: true, if_not_exists: true,
              name: 'idx_evo_go_health_monitors_observed_unique'
    add_check_constraint :evolution_go_health_monitors,
                         'failure_threshold > 0 AND recovery_threshold > 0 AND cooldown_minutes >= 0',
                         name: 'evo_go_health_monitors_positive_thresholds', if_not_exists: true
  end
end
