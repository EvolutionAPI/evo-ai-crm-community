class CreateScheduledPosts < ActiveRecord::Migration[7.1]
  def change
    # uuid (não bigint, ao contrário de scheduled_actions): precisa de
    # has_one_attached :media, e active_storage_attachments.record_id nesta
    # app é uuid — um PK bigint grava NULL silenciosamente ali (o adapter do
    # Postgres faz cast de um Integer inválido pra coluna uuid como nil, sem
    # erro de tipo) e o attach falha com NotNullViolation.
    create_table :scheduled_posts, id: :uuid, if_not_exists: true do |t|
      t.uuid :created_by, null: false
      t.text :caption
      t.string :platforms, array: true, null: false, default: []
      t.string :content_type, null: false
      t.string :channel_type, null: false
      t.string :channel_id, null: false
      t.datetime :scheduled_for, null: false
      t.string :status, null: false, default: 'scheduled'
      t.text :error_message
      t.integer :retry_count, null: false, default: 0
      t.integer :max_retries, null: false, default: 3
      t.jsonb :external_post_ids, null: false, default: {}

      t.timestamps
    end

    add_index :scheduled_posts, :status, if_not_exists: true
    add_index :scheduled_posts, :scheduled_for, if_not_exists: true
    add_index :scheduled_posts, :created_by, if_not_exists: true
  end
end
