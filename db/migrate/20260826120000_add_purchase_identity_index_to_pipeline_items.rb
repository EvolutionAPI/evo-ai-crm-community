# frozen_string_literal: true

# Idempotency backstop for purchase-webhook lead capture: a redelivered (or
# concurrently retried) purchase must not mint a second card. The (provider,
# purchase_id) pair lives in custom_fields['purchase']; the partial UNIQUE
# expression index makes the pair the source of truth — the service answers
# RecordNotUnique as an idempotent "duplicate" ack. Scoped by pipeline_id:
# purchase ids are only unique within one platform ACCOUNT, and distinct
# installations/pipelines may legitimately see the same id — a global pair
# would swallow the second sale as a false duplicate. The registered webhook
# URL pins the pipeline, so redeliveries land on the same scope. Partial
# because only purchase-captured cards carry the key; expression because the
# GIN index on custom_fields does not serve ->> equality (same rationale as
# index_pipeline_items_on_lead_form_slug).
class AddPurchaseIdentityIndexToPipelineItems < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  INDEX_NAME = 'index_pipeline_items_on_purchase_identity'
  PROVIDER_EXPR = "(custom_fields -> 'purchase' ->> 'provider')"
  PURCHASE_EXPR = "(custom_fields -> 'purchase' ->> 'purchase_id')"

  def up
    add_index :pipeline_items, "pipeline_id, #{PROVIDER_EXPR}, #{PURCHASE_EXPR}",
              unique: true, name: INDEX_NAME,
              where: "#{PURCHASE_EXPR} IS NOT NULL",
              algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :pipeline_items, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
