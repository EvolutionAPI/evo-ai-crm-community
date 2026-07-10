# frozen_string_literal: true

# PipelineStageSerializer - Optimized serialization for PipelineStage resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   PipelineStageSerializer.serialize(@pipeline_stage)
#
module PipelineStageSerializer
  extend self

  # Serialize single PipelineStage
  #
  # @param pipeline_stage [PipelineStage] PipelineStage to serialize
  # @param options [Hash] Serialization options
  #
  # @return [Hash] Serialized pipeline stage ready for Oj
  #
  def serialize(pipeline_stage, include_item_count: false)
    result = {
      id: pipeline_stage.id,
      name: pipeline_stage.name,
      pipeline_id: pipeline_stage.pipeline_id,
      position: pipeline_stage.position,
      color: pipeline_stage.color,
      stage_type: pipeline_stage.stage_type,
      automation_rules: pipeline_stage.automation_rules || {},
      custom_fields: pipeline_stage.custom_fields || {},
      created_at: pipeline_stage.created_at&.iso8601,
      updated_at: pipeline_stage.updated_at&.iso8601
    }

    if include_item_count
      result[:item_count] = pipeline_stage.item_count
      # Per-stage services total (same services_total_value the pipeline/board sum on).
      # Lets the list surface value-per-stage (e.g. the "Ganhos"/completed-stage value)
      # without loading every item into the list payload.
      result[:total_value] = pipeline_stage.pipeline_items.sum(&:services_total_value)
    end

    result
  end

  # Serialize collection of PipelineStages
  #
  # @param pipeline_stages [Array<PipelineStage>, ActiveRecord::Relation]
  #
  # @return [Array<Hash>] Array of serialized pipeline stages
  #
  def serialize_collection(pipeline_stages)
    return [] unless pipeline_stages

    pipeline_stages.map { |stage| serialize(stage) }
  end
end
