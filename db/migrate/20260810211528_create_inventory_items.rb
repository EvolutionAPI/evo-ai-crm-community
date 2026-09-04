class CreateInventoryItems < ActiveRecord::Migration[7.1]
  def change
    create_table :inventory_items, id: :uuid do |t|
      t.string :name, null: false
      t.string :sku
      t.string :unit, default: "un"
      t.decimal :quantity, precision: 10, scale: 2, default: 0.0, null: false
      t.decimal :min_quantity, precision: 10, scale: 2, default: 5.0, null: false
      t.timestamps
    end
    add_index :inventory_items, :sku, unique: true if index_exists?(:inventory_items, :sku) == false
  end
end
