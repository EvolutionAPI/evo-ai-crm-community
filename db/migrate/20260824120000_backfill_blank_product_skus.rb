# frozen_string_literal: true

# CRM-289: before the model normalized it, a create with sku: "" persisted the
# empty string, which the partial unique index (WHERE sku IS NOT NULL) treats as
# a real value. Those rows keep serializing "" while every new no-SKU product is
# NULL, so the API answers two different shapes for the same "no SKU".
class BackfillBlankProductSkus < ActiveRecord::Migration[7.1]
  TABLES = %i[products product_variants].freeze

  def up
    TABLES.each do |table|
      next unless table_exists?(table)

      # Matches ActiveSupport's blank? for strings — "" and whitespace-only.
      updated = execute(<<~SQL.squish).cmd_tuples
        UPDATE #{table} SET sku = NULL WHERE sku ~ '^[[:space:]]*$'
      SQL

      say "#{table}: #{updated} blank sku(s) normalized to NULL", true
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'A blank sku is indistinguishable from an absent one once normalized.'
  end
end
