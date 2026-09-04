class CreateWorkOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :work_orders, id: :uuid, if_not_exists: true do |t|
      t.string :os_number, null: false, limit: 50
      t.string :status, null: false, default: 'open', limit: 20

      # Dados do cliente (denormalizados, fiel ao fluxo HTML)
      t.string :client_name, limit: 255
      t.string :client_cpf, limit: 20
      t.string :client_phone, limit: 40
      t.string :client_email, limit: 255
      t.string :client_instagram, limit: 255
      t.string :client_gender, limit: 20
      t.date :client_birthdate
      t.string :client_cep, limit: 20
      t.string :client_address, limit: 255
      t.string :client_number, limit: 20
      t.string :client_neighborhood, limit: 100
      t.string :client_city, limit: 100
      t.string :client_state, limit: 20

      # Detalhes do serviço
      t.string :device, limit: 255
      t.text :problems
      t.text :checklist
      t.text :observation
      t.string :device_password, limit: 100

      t.datetime :entry_date
      t.date :pickup_date
      t.boolean :device_turns_on, default: true, null: false
      t.boolean :picked_up, default: false, null: false

      # Itens adicionados à OS (array de objetos)
      t.jsonb :items, null: false, default: []

      # Valores
      t.decimal :base_value, precision: 10, scale: 2, null: false, default: 0.0
      t.decimal :discount, precision: 10, scale: 2, null: false, default: 0.0
      t.decimal :total, precision: 10, scale: 2, null: false, default: 0.0
      t.string :payment_method, limit: 40, null: false, default: 'Não Definido'
      t.integer :installments

      t.timestamps
    end

    add_index :work_orders, :os_number, unique: true, if_not_exists: true
    add_index :work_orders, :status, if_not_exists: true
    add_index :work_orders, :client_name, if_not_exists: true
    add_index :work_orders, :entry_date, if_not_exists: true
    add_index :work_orders, :items, using: :gin, if_not_exists: true

    add_check_constraint :work_orders, "(base_value >= 0)", name: 'work_orders_base_value_non_negative', if_not_exists: true
    add_check_constraint :work_orders, "(discount >= 0)", name: 'work_orders_discount_non_negative', if_not_exists: true
    add_check_constraint :work_orders, "(total >= 0)", name: 'work_orders_total_non_negative', if_not_exists: true
  end
end
