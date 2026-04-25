class MakeAttachmentPolymorphic < ActiveRecord::Migration[7.1]
  def up
    # Adicionar colunas polimórficas
    add_column :attachments, :attachable_type, :string unless column_exists?(:attachments, :attachable_type)
    add_column :attachments, :attachable_id, :uuid unless column_exists?(:attachments, :attachable_id)

    # Migrar dados existentes (Message -> attachable)
    if column_exists?(:attachments, :message_id)
      execute <<-SQL
        UPDATE attachments
        SET attachable_type = 'Message',
            attachable_id = message_id
        WHERE message_id IS NOT NULL AND attachable_type IS NULL
      SQL
    end

    # Adicionar índice polimórfico
    if column_exists?(:attachments, :attachable_type) && column_exists?(:attachments, :attachable_id)
      add_index :attachments, [:attachable_type, :attachable_id] unless index_exists?(:attachments, [:attachable_type, :attachable_id])
    end

    # Remover coluna antiga e índice antigo
    if column_exists?(:attachments, :message_id)
      remove_index :attachments, :message_id if index_exists?(:attachments, :message_id)
      remove_column :attachments, :message_id
    end
  end

  def down
    # Reverter mudanças
    add_column :attachments, :message_id, :uuid

    reversible do |dir|
      dir.down do
        execute <<-SQL
          UPDATE attachments
          SET message_id = attachable_id
          WHERE attachable_type = 'Message'
        SQL
      end
    end

    add_index :attachments, :message_id
    remove_index :attachments, [:attachable_type, :attachable_id]
    remove_column :attachments, :attachable_type
    remove_column :attachments, :attachable_id
  end
end
