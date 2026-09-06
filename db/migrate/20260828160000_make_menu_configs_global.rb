class MakeMenuConfigsGlobal < ActiveRecord::Migration[7.1]
  def up
    # Consolida: por scope, mantém a linha com o payload mais "rico" (mais
    # conteúdo) — evita perder itens reais em favor de uma linha vazia mais
    # recente (era exatamente o bug: usuário novo cria uma linha vazia própria
    # e ela nunca herdava o conteúdo do dono original).
    execute <<~SQL.squish
      DELETE FROM menu_configs
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (
            PARTITION BY scope
            ORDER BY length(payload::text) DESC, updated_at DESC
          ) AS rn
          FROM menu_configs
        ) ranked
        WHERE rn > 1
      )
    SQL

    remove_index :menu_configs, name: 'index_menu_configs_on_user_and_scope', if_exists: true
    remove_index :menu_configs, column: :user_id, if_exists: true
    remove_foreign_key :menu_configs, :users, if_exists: true
    change_column_null :menu_configs, :user_id, true
    add_index :menu_configs, :scope, unique: true, if_not_exists: true
  end

  def down
    add_index :menu_configs, [:user_id, :scope], unique: true, name: 'index_menu_configs_on_user_and_scope', if_not_exists: true
    add_index :menu_configs, :user_id, if_not_exists: true
  end
end
