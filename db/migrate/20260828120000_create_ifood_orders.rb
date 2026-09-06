class CreateIfoodOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :ifood_orders, id: :uuid, if_not_exists: true do |t|
      t.string :ifood_order_id, null: false, limit: 100
      t.string :display_id, limit: 20
      t.string :status, null: false, default: 'PLACED', limit: 30
      t.string :order_type, limit: 30
      t.string :customer_name, limit: 255
      t.string :customer_phone, limit: 40
      t.decimal :total_price, precision: 10, scale: 2, null: false, default: 0.0
      t.jsonb :items, null: false, default: []
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :placed_at

      t.timestamps
    end

    add_index :ifood_orders, :ifood_order_id, unique: true, if_not_exists: true
    add_index :ifood_orders, :status, if_not_exists: true
    add_index :ifood_orders, :placed_at, if_not_exists: true
  end
end
