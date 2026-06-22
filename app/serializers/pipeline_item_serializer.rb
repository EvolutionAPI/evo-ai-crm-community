# frozen_string_literal: true

# PipelineItemSerializer - Optimized serialization for PipelineItem resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   PipelineItemSerializer.serialize(@pipeline_item, include_entity: true)
#
module PipelineItemSerializer
  extend self

  # Serialize single PipelineItem
  #
  # @param pipeline_item [PipelineItem] PipelineItem to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_entity Include entity details (conversation or contact)
  #
  # @return [Hash] Serialized pipeline item ready for Oj
  #
  # Build a per-item task-count index in bulk, so callers serializing many items
  # don't fire 5 COUNT queries per item (N+1). Mirrors the labels_by_* batching
  # below. Pass the result as `task_counts_by_item:` to #serialize.
  #
  # @param items [Array<PipelineItem>, ActiveRecord::Relation]
  # @return [Hash{String => Hash}] item_id => {pending:, overdue:, due_soon:, completed:, total:}
  def task_counts_for(items)
    ids = items.map(&:id)
    return {} if ids.empty?

    # status is an integer-backed enum, but Rails (7.1) returns the string label
    # as the group key here (verified against prod: keys are ["<uuid>", "pending"]).
    # Key the lookups by label string accordingly.
    by_status = PipelineTask.where(pipeline_item_id: ids).group(:pipeline_item_id, :status).count
    totals    = PipelineTask.where(pipeline_item_id: ids).group(:pipeline_item_id).count
    due_soon  = PipelineTask.where(pipeline_item_id: ids)
                            .where('due_date > ? AND due_date <= ?', Time.current, 1.hour.from_now)
                            .group(:pipeline_item_id).count

    ids.index_with do |id|
      {
        pending: by_status.fetch([id, 'pending'], 0),
        overdue: by_status.fetch([id, 'overdue'], 0),
        due_soon: due_soon.fetch(id, 0),
        completed: by_status.fetch([id, 'completed'], 0),
        total: totals.fetch(id, 0)
      }
    end
  end

  def serialize(pipeline_item, include_entity: false, include_tasks_info: false,
                include_services_info: false, include_labels: false,
                labels_by_title: nil, labels_by_id: nil, task_counts_by_item: nil)
    is_orphaned = if pipeline_item.conversation_id.present?
                    !pipeline_item.conversation.present?
                  elsif pipeline_item.contact_id.present?
                    !pipeline_item.contact.present?
                  else
                    true
                  end

    result = {
      id: pipeline_item.id,
      pipeline_id: pipeline_item.pipeline_id,
      pipeline_stage_id: pipeline_item.pipeline_stage_id,
      stage_id: pipeline_item.pipeline_stage_id,
      conversation_id: pipeline_item.conversation_id,
      contact_id: pipeline_item.contact_id,
      item_id: pipeline_item.conversation_id || pipeline_item.contact_id,
      type: pipeline_item.lead? ? 'contact' : 'conversation',
      is_lead: pipeline_item.lead?,
      custom_fields: pipeline_item.custom_fields || {},
      entered_at: pipeline_item.entered_at&.to_i,
      completed_at: pipeline_item.completed_at&.to_i,
      days_in_pipeline: pipeline_item.days_in_pipeline,
      days_in_current_stage: pipeline_item.days_in_current_stage,
      created_at: pipeline_item.created_at&.to_i,
      updated_at: pipeline_item.updated_at&.iso8601,
      is_orphaned: is_orphaned
    }

    return result if is_orphaned
    if include_entity && pipeline_item.conversation.present? && pipeline_item.association(:conversation).loaded? && pipeline_item.conversation
      result[:conversation] = ConversationSerializer.serialize(
        pipeline_item.conversation,
        include_messages: false,
        include_labels: include_labels,
        labels_by_title: labels_by_title,
        labels_by_id: labels_by_id
      )
      result[:conversation]['uuid'] = pipeline_item.conversation.uuid
      if pipeline_item.conversation.association(:contact).loaded? && pipeline_item.conversation.contact
        # include_labels: false — the pipelines board does not render contact labels
        # (it uses conversation.labels), and contact.labels triggers an N+1 (tags load
        # + a Label.find_by per tag). Skipping it keeps GET /pipelines off the timeout.
        result[:contact] = ContactSerializer.serialize(pipeline_item.conversation.contact, include_labels: false)
      end
      if pipeline_item.conversation.association(:assignee).loaded? && pipeline_item.conversation.assignee
        result[:assignee] = {
          id: pipeline_item.conversation.assignee.id,
          name: pipeline_item.conversation.assignee.name,
          email: pipeline_item.conversation.assignee.email,
          avatar_url: pipeline_item.conversation.assignee.avatar_url,
          available_name: pipeline_item.conversation.assignee.available_name
        }
      end
    end

    if include_entity && pipeline_item.contact.present? && pipeline_item.association(:contact).loaded? && pipeline_item.contact
      # include_labels: false — see note above; pipelines board does not use contact labels.
      result[:contact] = ContactSerializer.serialize(pipeline_item.contact, include_labels: false)
    end

    # Include tasks info if requested. When a pre-computed batch index is passed
    # (collection serialization), read from it to avoid 5 COUNT queries per item.
    # Falls back to the per-item methods for single-item callers (e.g. #show).
    if include_tasks_info
      counts = task_counts_by_item && task_counts_by_item[pipeline_item.id]
      result[:tasks_info] = if counts
                              {
                                pending_count: counts[:pending],
                                overdue_count: counts[:overdue],
                                due_soon_count: counts[:due_soon],
                                completed_count: counts[:completed],
                                total_count: counts[:total]
                              }
                            else
                              {
                                pending_count: pipeline_item.pending_tasks_count,
                                overdue_count: pipeline_item.overdue_tasks_count,
                                due_soon_count: pipeline_item.due_soon_tasks_count,
                                completed_count: pipeline_item.completed_tasks_count,
                                total_count: pipeline_item.tasks.count
                              }
                            end
    end

    # Include services info if requested
    if include_services_info
      currency = pipeline_item.custom_fields&.dig('currency') || 'BRL'
      total_value = pipeline_item.services_total_value
      services = pipeline_item.custom_fields&.dig('services') || []
      
      result[:services_info] = {
        total_value: total_value,
        currency: currency,
        formatted_total: pipeline_item.formatted_services_total(currency),
        services_count: services.length,
        has_services: services.any? && total_value > 0,
        services: services.map do |service|
          service_info = {
            name: service['name'],
            value: service['value'].to_f
          }
          service_info[:service_definition_id] = service['service_definition_id'] if service['service_definition_id'].present?
          service_info
        end
      }
      result[:value] = total_value
    end

    result
  end

  # Serialize collection of PipelineItems
  #
  # @param pipeline_items [Array<PipelineItem>, ActiveRecord::Relation]
  #
  # @return [Array<Hash>] Array of serialized pipeline items
  #
  def serialize_collection(pipeline_items, **options)
    return [] unless pipeline_items

    pipeline_items.map { |item| serialize(item, **options) }
  end
end
