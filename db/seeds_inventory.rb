items = [
  { name: "Pão Brioche", sku: "ING-PAO", unit: "un", quantity: 150, min_quantity: 30 },
  { name: "Hambúrguer 160g", sku: "ING-CARNE", unit: "un", quantity: 200, min_quantity: 40 },
  { name: "Queijo Prato (Fatias)", sku: "ING-QUEIJO", unit: "kg", quantity: 15.0, min_quantity: 3.0 },
  { name: "Bacon (Fatias)", sku: "ING-BACON", unit: "kg", quantity: 10.0, min_quantity: 2.0 },
  { name: "Ovos", sku: "ING-OVO", unit: "un", quantity: 120, min_quantity: 30 },
  { name: "Batata Frita (Congelada)", sku: "ING-BATATA", unit: "kg", quantity: 25.0, min_quantity: 5.0 },
  { name: "Coca-Cola Lata 350ml", sku: "EST-COCA", unit: "un", quantity: 80, min_quantity: 20 },
  { name: "Coca-Cola Zero Lata 350ml", sku: "EST-COCAZERO", unit: "un", quantity: 60, min_quantity: 15 },
  { name: "Guaraná Lata 350ml", sku: "EST-GUARANA", unit: "un", quantity: 70, min_quantity: 20 }
]

items.each do |data|
  item = InventoryItem.find_or_initialize_by(sku: data[:sku])
  item.assign_attributes(data)
  item.save!
  puts "Estoque cadastrado: #{item.name} (#{item.quantity} #{item.unit})"
end
