# frozen_string_literal: true

# Idempotency backstop for purchase-webhook lead capture: a redelivered purchase
# must not mint a second card. Scoped by pipeline_id because purchase ids are
# unique only within one platform ACCOUNT — a global pair would swallow another
# funnel's sale as a false duplicate. Expression index because the GIN index on
# custom_fields does not serve ->> equality (as index_pipeline_items_on_lead_form_slug).
class AddPurchaseIdentityIndexToPipelineItems < ActiveRecord::Migration[7.1]
  include ConcurrentIndexMigration

  disable_ddl_transaction!

  INDEX_NAME = 'index_pipeline_items_on_purchase_identity'
  PROVIDER_EXPR = "(custom_fields -> 'purchase' ->> 'provider')"
  PURCHASE_EXPR = "(custom_fields -> 'purchase' ->> 'purchase_id')"

  def up
    add_index_concurrently :pipeline_items, "pipeline_id, #{PROVIDER_EXPR}, #{PURCHASE_EXPR}",
                           name: INDEX_NAME, unique: true,
                           where: "#{PURCHASE_EXPR} IS NOT NULL"
  end

  def down
    remove_index :pipeline_items, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
