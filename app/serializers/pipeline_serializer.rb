# frozen_string_literal: true

# PipelineSerializer - Optimized serialization for Pipeline resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   PipelineSerializer.serialize(@pipeline, include_stages: true)
#
module PipelineSerializer
  extend self

  # Serialize single Pipeline
  #
  # @param pipeline [Pipeline] Pipeline to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_stages Include pipeline stages
  # @option options [Boolean] :include_items Include pipeline items
  #
  # @return [Hash] Serialized pipeline ready for Oj
  #
  def serialize(pipeline, include_stages: false, include_items: false,
                include_tasks_info: false, include_services_info: false,
                include_labels: false, labels_by_title: nil, labels_by_id: nil,
                task_counts_by_item: nil)
    result = {
      id: pipeline.id,
      name: pipeline.name,
      created_by_id: pipeline.created_by_id,
      description: pipeline.description,
      pipeline_type: pipeline.pipeline_type,
      visibility: pipeline.visibility,
      is_active: pipeline.is_active,
      is_default: pipeline.is_default,
      custom_fields: pipeline.custom_fields || {},
      item_count: pipeline.item_count,
      conversations_count: pipeline.item_count, # Alias for frontend compatibility
      created_at: pipeline.created_at&.iso8601,
      updated_at: pipeline.updated_at&.iso8601
    }

    # Include stages if loaded
    if include_stages && pipeline.association(:pipeline_stages).loaded?
      # Order stages by position
      ordered_stages = pipeline.pipeline_stages.order(:position)
      
      # If items are also included, attach them directly to each stage
      if include_items && pipeline.association(:pipeline_items).loaded?
        # Build label indexes once for the entire pipeline if labels are requested
        # but no pre-built indexes were provided. Caller can override by passing
        # labels_by_title / labels_by_id to avoid the Label.all query when batching.
        if include_labels && (labels_by_title.nil? || labels_by_id.nil?)
          all_labels = Label.all.to_a
          labels_by_title ||= all_labels.index_by { |label| label.title.to_s.downcase }
          labels_by_id ||= all_labels.index_by { |label| label.id.to_s }
        end

        # Serialize only active items (completed journeys are accessible via pipeline_items endpoint with status=completed)
        active_items = pipeline.pipeline_items.select { |item| item.completed_at.nil? }

        # Batch task counts once for this pipeline's active items to avoid the
        # 5-COUNT-per-item N+1 inside PipelineItemSerializer. Caller can override
        # by passing task_counts_by_item (e.g. to batch across multiple pipelines).
        item_task_counts = if include_tasks_info
                             task_counts_by_item || PipelineItemSerializer.task_counts_for(active_items)
                           end

        serialized_items = active_items.map do |item|
          PipelineItemSerializer.serialize(
            item,
            include_entity: true,
            include_tasks_info: include_tasks_info,
            include_services_info: include_services_info,
            include_labels: include_labels,
            labels_by_title: labels_by_title,
            labels_by_id: labels_by_id,
            task_counts_by_item: item_task_counts
          )
        end

        # Group items by stage_id for efficient lookup
        items_by_stage = serialized_items.group_by { |item| item[:stage_id] }

        # Serialize stages with items already included
        result[:stages] = ordered_stages.map do |stage|
          stage_data = PipelineStageSerializer.serialize(stage, include_item_count: true)
          # Include items directly in the stage
          stage_data[:items] = items_by_stage[stage.id] || []
          stage_data
        end
      else
        # Just serialize stages without items
        result[:stages] = ordered_stages.map do |stage|
          PipelineStageSerializer.serialize(stage, include_item_count: true)
        end
      end
    end

    result
  end

  # Serialize collection of Pipelines
  #
  # @param pipelines [Array<Pipeline>, ActiveRecord::Relation]
  #
  # @return [Array<Hash>] Array of serialized pipelines
  #
  def serialize_collection(pipelines, **options)
    return [] unless pipelines

    pipelines.map { |pipeline| serialize(pipeline, **options) }
  end
end
