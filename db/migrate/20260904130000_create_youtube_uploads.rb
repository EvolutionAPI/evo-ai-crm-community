class CreateYoutubeUploads < ActiveRecord::Migration[7.1]
  def change
    create_table :youtube_uploads, id: :uuid, if_not_exists: true do |t|
      t.uuid :created_by, null: false
      t.string :title, null: false
      t.text :description
      t.string :privacy_status, null: false, default: 'unlisted'
      t.string :status, null: false, default: 'pending'
      t.text :error_message
      t.string :external_video_id

      t.timestamps
    end

    add_index :youtube_uploads, :status, if_not_exists: true
    add_index :youtube_uploads, :created_by, if_not_exists: true
  end
end
