class CreateNinetyNineOrders < ActiveRecord::Migration[7.1]
  def change
    # A 99 (99Food) não expõe uma API de polling como o iFood — a integração
    # é via webhook (99 empurra os eventos pra gente). Como ainda não
    # recebemos nenhum payload real, guardamos o raw_payload sempre; os
    # campos estruturados abaixo são melhor-esforço (nil-safe) até
    # confirmarmos o formato exato com o primeiro webhook de verdade.
    create_table :ninety_nine_orders, id: :uuid, if_not_exists: true do |t|
      t.string :external_order_id, limit: 100
      t.string :status, limit: 30
      t.string :customer_name, limit: 255
      t.string :customer_phone, limit: 40
      t.decimal :total_price, precision: 10, scale: 2
      t.jsonb :items, null: false, default: []
      t.jsonb :raw_payload, null: false, default: {}
      t.datetime :received_at, null: false

      t.timestamps
    end

    add_index :ninety_nine_orders, :external_order_id, if_not_exists: true
    add_index :ninety_nine_orders, :received_at, if_not_exists: true
  end
end
