class CreateChatPages < ActiveRecord::Migration[7.1]
  def change
    create_table :chat_pages, id: :uuid do |t|
      t.string :slug, null: false, limit: 255
      t.string :title, limit: 255
      t.text :description
      t.jsonb :appearance, null: false, default: {}
      t.string :website_token, null: false
      t.boolean :published, null: false, default: false

      t.timestamps
    end

    add_index :chat_pages, :slug, unique: true
    add_index :chat_pages, :published
    add_index :chat_pages, :website_token

    add_check_constraint :chat_pages, "slug != ''", name: 'chat_pages_slug_not_empty'
    add_check_constraint :chat_pages, "website_token != ''", name: 'chat_pages_website_token_not_empty'
  end
end
