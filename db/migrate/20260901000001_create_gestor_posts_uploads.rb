class CreateGestorPostsUploads < ActiveRecord::Migration[7.1]
  def change
    create_table :gestor_posts_uploads, id: :uuid, if_not_exists: true do |t|
      t.uuid :created_by, null: false
      t.text :caption
      t.string :platforms, array: true, null: false, default: []
      t.string :content_type, null: false # feed | stories | reels
      t.string :status, null: false, default: 'pending'
      t.text :error_message
      t.jsonb :external_post_ids, null: false, default: {}

      t.timestamps
    end

    add_index :gestor_posts_uploads, :status, if_not_exists: true
    add_index :gestor_posts_uploads, :created_by, if_not_exists: true
  end
end
