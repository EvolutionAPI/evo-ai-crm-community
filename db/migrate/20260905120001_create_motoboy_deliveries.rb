class CreateMotoboyDeliveries < ActiveRecord::Migration[7.1]
  def change
    create_table :motoboy_deliveries, id: :uuid, if_not_exists: true do |t|
      t.uuid :motoboy_id, null: false
      # Pedidos da Esteira vêm de planilha/iFood via webhook (n8n), não do banco
      # do CRM — não existe um order_id local pra referenciar. order_external_id
      # + platform é a chave natural desses pedidos (mesmo par usado no card na
      # Esteira de Pedidos).
      t.string :order_external_id, null: false
      t.string :platform, null: false, default: 'proprio'
      t.string :customer_name
      t.string :address
      t.string :status, null: false, default: 'atribuido'
      t.datetime :assigned_at
      t.datetime :delivered_at

      t.timestamps
    end

    add_index :motoboy_deliveries, [:order_external_id, :platform], unique: true, name: 'index_motoboy_deliveries_on_order_and_platform', if_not_exists: true
    add_index :motoboy_deliveries, :motoboy_id, if_not_exists: true
    add_index :motoboy_deliveries, :status, if_not_exists: true
  end
end
