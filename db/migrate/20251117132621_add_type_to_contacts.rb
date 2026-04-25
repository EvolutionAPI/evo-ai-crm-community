class AddTypeToContacts < ActiveRecord::Migration[7.1]
  def up
    # Criar tipo ENUM no PostgreSQL
    execute <<-SQL
      DO $$ BEGIN
        CREATE TYPE contact_type_enum AS ENUM ('person', 'company');
      EXCEPTION
        WHEN duplicate_object THEN null;
      END $$;
    SQL

    # Adicionar coluna com ENUM
    unless column_exists?(:contacts, :type)
      add_column :contacts, :type, :contact_type_enum, default: 'person', null: false
    end

    add_index :contacts, :type unless index_exists?(:contacts, :type)

    # Atualizar contatos existentes para 'person'
    Contact.where(type: nil).update_all(type: 'person') if column_exists?(:contacts, :type)
  end

  def down
    remove_index :contacts, :type
    remove_column :contacts, :type
    
    # Remover tipo ENUM do PostgreSQL
    execute <<-SQL
      DROP TYPE IF EXISTS contact_type_enum;
    SQL
  end
end
