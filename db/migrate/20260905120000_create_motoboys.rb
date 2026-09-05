class CreateMotoboys < ActiveRecord::Migration[7.1]
  def change
    create_table :motoboys, id: :uuid, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :phone
      t.string :vehicle_type, null: false, default: 'moto'
      t.string :status, null: false, default: 'disponivel'
      t.boolean :active, null: false, default: true
      t.text :notes

      t.timestamps
    end

    add_index :motoboys, :status, if_not_exists: true
    add_index :motoboys, :active, if_not_exists: true
  end
end
