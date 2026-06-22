# frozen_string_literal: true

# Heals installations where the stage_movements column/FK rename from
# 20251119170940 (pipeline_conversations -> pipeline_items) was recorded as
# applied but never took effect on stage_movements, leaving the old column
# `pipeline_conversation_id` (FK to the orphaned pipeline_conversations table).
# The app expects `pipeline_item_id`, so any StageMovement write fails with
# "unknown attribute 'pipeline_item_id'".
#
# Idempotent / heal-forward: a no-op on schemas that are already correct.
class HealStageMovementsPipelineItemFk < ActiveRecord::Migration[7.1]
  def up
    return unless column_exists?(:stage_movements, :pipeline_conversation_id)

    if foreign_key_exists?(:stage_movements, column: :pipeline_conversation_id)
      remove_foreign_key :stage_movements, column: :pipeline_conversation_id
    end

    rename_column :stage_movements, :pipeline_conversation_id, :pipeline_item_id

    if index_name_exists?(:stage_movements, 'index_stage_movements_on_pipeline_conversation_id')
      rename_index :stage_movements,
                   'index_stage_movements_on_pipeline_conversation_id',
                   'index_stage_movements_on_pipeline_item_id'
    end

    add_foreign_key :stage_movements, :pipeline_items, column: :pipeline_item_id unless foreign_key_exists?(:stage_movements, :pipeline_items)
  end

  def down
    # Heal-forward only.
  end
end
