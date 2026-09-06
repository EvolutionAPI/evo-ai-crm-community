class AddCategoriesMediaAndIngredientsToProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :product_categories, id: :uuid do |t|
      t.string :name, null: false
      t.timestamps
    end
    add_index :product_categories, :name, unique: true

    add_column :products, :category_id, :uuid, if_not_exists: true
    add_column :products, :media, :jsonb, default: [], null: false, if_not_exists: true
    add_foreign_key :products, :product_categories, column: :category_id

    create_table :product_ingredients, id: :uuid do |t|
      t.uuid :product_id, null: false
      t.uuid :ingredient_product_id, null: false
      t.decimal :quantity, precision: 14, scale: 3, null: false, default: 0.0
      t.string :unit, default: 'un', null: false
      t.timestamps
    end
    add_index :product_ingredients, :product_id
    add_index :product_ingredients, :ingredient_product_id
    add_index :product_ingredients, %i[product_id ingredient_product_id], unique: true, name: 'idx_product_ingredients_unique'
    add_foreign_key :product_ingredients, :products, column: :product_id, on_delete: :cascade
    add_foreign_key :product_ingredients, :products, column: :ingredient_product_id, on_delete: :cascade
  end
end