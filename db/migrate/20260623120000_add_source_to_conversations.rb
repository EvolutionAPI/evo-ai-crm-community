class AddSourceToConversations < ActiveRecord::Migration[7.0]
  def change
    add_column :conversations, :source, :integer, default: 0, null: false
  end
end
