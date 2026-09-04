class CreateCarouselUploadBatches < ActiveRecord::Migration[7.1]
  def change
    create_table :carousel_upload_batches, id: :uuid, if_not_exists: true do |t|
      t.uuid :created_by, null: false
      t.text :caption
      t.string :platforms, array: true, null: false, default: []
      t.string :channel_type, null: false
      t.string :channel_id, null: false
      t.integer :total_cards, null: false
      t.jsonb :container_ids, null: false, default: {}
      t.string :status, null: false, default: 'collecting'
      t.text :error_message
      t.jsonb :external_post_ids, null: false, default: {}

      t.timestamps
    end

    add_index :carousel_upload_batches, :status, if_not_exists: true
    add_index :carousel_upload_batches, :created_by, if_not_exists: true
  end
end
