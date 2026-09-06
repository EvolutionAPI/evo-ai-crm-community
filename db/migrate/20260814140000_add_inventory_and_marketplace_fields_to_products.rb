class AddInventoryAndMarketplaceFieldsToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :cost_price, :decimal, precision: 10, scale: 2, if_not_exists: true
    add_column :products, :supplier, :string, limit: 255, if_not_exists: true
    add_column :products, :material, :text, if_not_exists: true
    add_column :products, :color, :string, limit: 100, if_not_exists: true
    add_column :products, :size, :string, limit: 100, if_not_exists: true
    add_column :products, :weight_kg, :decimal, precision: 10, scale: 3, if_not_exists: true
    add_column :products, :height_cm, :decimal, precision: 10, scale: 2, if_not_exists: true
    add_column :products, :width_cm, :decimal, precision: 10, scale: 2, if_not_exists: true
    add_column :products, :length_cm, :decimal, precision: 10, scale: 2, if_not_exists: true
    add_column :products, :item_type, :string, limit: 20, default: 'produto', null: false, if_not_exists: true
    add_column :products, :ml_category, :string, limit: 100, if_not_exists: true
    add_column :products, :ml_buying_model, :string, limit: 100, if_not_exists: true
    add_column :products, :ml_listing_type, :string, limit: 100, if_not_exists: true
    add_column :products, :ml_condition, :string, limit: 100, if_not_exists: true
    add_column :products, :brand, :string, limit: 255, if_not_exists: true
    add_column :products, :model, :string, limit: 255, if_not_exists: true
    add_column :products, :compatible_brands, :string, limit: 500, if_not_exists: true
    add_column :products, :accessory_type, :string, limit: 255, if_not_exists: true
    add_column :products, :anatel_number, :string, limit: 100, if_not_exists: true
    add_column :products, :publish_ml, :boolean, default: false, null: false, if_not_exists: true

    add_index :products, :item_type, if_not_exists: true
    add_index :products, :supplier, if_not_exists: true

    add_check_constraint :products, "(cost_price IS NULL) OR (cost_price >= 0)", name: 'products_cost_price_non_negative', if_not_exists: true
    add_check_constraint :products, "(weight_kg IS NULL) OR (weight_kg >= 0)", name: 'products_weight_kg_non_negative', if_not_exists: true
    add_check_constraint :products, "(height_cm IS NULL) OR (height_cm >= 0)", name: 'products_height_cm_non_negative', if_not_exists: true
    add_check_constraint :products, "(width_cm IS NULL) OR (width_cm >= 0)", name: 'products_width_cm_non_negative', if_not_exists: true
    add_check_constraint :products, "(length_cm IS NULL) OR (length_cm >= 0)", name: 'products_length_cm_non_negative', if_not_exists: true
  end
end
