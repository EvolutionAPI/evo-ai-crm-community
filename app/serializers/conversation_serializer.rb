# frozen_string_literal: true

# ConversationSerializer - Optimized serialization for Conversation resources
#
# Plain Ruby module designed for Oj direct serialization
#
# Usage:
#   ConversationSerializer.serialize(@conversation, include_messages: true)
#   ConversationSerializer.serialize_collection(@conversations)
#
module ConversationSerializer
  extend self

  # Serialize single Conversation with optimized field selection
  #
  # @param conversation [Conversation] Conversation to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_messages Include messages association
  # @option options [Boolean] :include_labels Include labels
  # @option options [Boolean] :include_contact Include contact details
  # @option options [Boolean] :include_inbox Include inbox details
  #
  # @return [Hash] Serialized conversation ready for Oj
  #
  def serialize(
    conversation,
    include_messages: false,
    include_labels: false,
    include_contact: true,
    include_inbox: true,
    unread_counts: nil,
    last_non_activity_messages: nil,
    labels_by_title: nil,
    labels_by_id: nil
  )
    result = conversation.as_json(
      only: [:id, :inbox_id, :status, :assignee_id, :team_id,
             :campaign_id, :display_id, :additional_attributes, :priority]
    )

    result['labels'] = []
    result['pipelines'] = []

    # Timestamps as integers for better performance
    result['created_at'] = conversation.created_at.to_i
    result['updated_at'] = conversation.updated_at.to_i
    result['agent_last_seen_at'] = conversation.agent_last_seen_at&.to_i
    result['contact_last_seen_at'] = conversation.contact_last_seen_at&.to_i
    result['waiting_since'] = conversation.waiting_since&.to_i
    result['first_reply_created_at'] = conversation.first_reply_created_at&.to_i
    result['snoozed_until'] = conversation.snoozed_until&.to_i
    result['last_activity_at'] = conversation.last_activity_at&.to_i
    result['timestamp'] = conversation.last_activity_at&.to_i
    if unread_counts
      result['unread_count'] = unread_counts[conversation.id] || 0
    else
      result['unread_count'] = conversation.unread_incoming_messages&.count || 0
    end
    result['custom_attributes'] = conversation.custom_attributes || {}

    # Include contact
    if include_contact && conversation.contact.present?
      result['contact'] = {
        id: conversation.contact.id,
        name: conversation.contact.name,
        email: conversation.contact.email,
        phone_number: conversation.contact.phone_number,
        thumbnail: conversation.contact.avatar_url,
        custom_attributes: conversation.contact.custom_attributes || {}
      }
    end

    # Include inbox
    if include_inbox && conversation.inbox.present?
      inbox_data = {
        id: conversation.inbox.id,
        name: conversation.inbox.name,
        channel_type: conversation.inbox.channel_type
      }

      # Provider pode não existir em todos os tipos de channel (ex: Channel::Telegram)
      if conversation.inbox.channel.respond_to?(:provider)
        inbox_data['provider'] = conversation.inbox.channel.provider
      end

      result['inbox'] = inbox_data
    end

    # Include assignee
    if conversation.assignee.present?
      result['assignee'] = UserSerializer.serialize(conversation.assignee)
    end

    # Include team
    if conversation.team.present?
      result['team'] = {
        id: conversation.team.id,
        name: conversation.team.name
      }
    end

    # Conditionally include labels
    if include_labels
      # Historical cached_label_list entries may be either human-readable titles
      # (post label_concern UUID→title normalization) or raw UUIDs (pre-fix data).
      # Resolve both so conversation cards keep rendering for legacy rows.
      title_index = labels_by_title || {}
      id_index = labels_by_id || {}
      result['labels'] = conversation.cached_label_list_array.filter_map do |tag|
        tag_str = tag.to_s
        label_record = title_index[tag_str.downcase] || id_index[tag_str]
        label_record ? LabelSerializer.serialize(label_record) : nil
      end
    else
      # If include_labels is false, ensure labels key exists as empty array
      result['labels'] = []
    end

    # Include pipelines with stages
    if conversation.association(:pipeline_items).loaded?
      # Group pipeline_items by pipeline
      pipelines_hash = {}
      stages_hash = {} # Track stages by pipeline_id => { stage_id => stage_data }
      stage_items_map = {} # Track pipeline_item for each stage to calculate days_in_current_stage

      conversation.pipeline_items.each do |item|
        pipeline = item.pipeline
        stage = item.pipeline_stage

        # Initialize pipeline if not already added
        unless pipelines_hash[pipeline.id]
          pipelines_hash[pipeline.id] = {
            id: pipeline.id,
            name: pipeline.name
          }
          stages_hash[pipeline.id] = {}
          stage_items_map[pipeline.id] = {}
        end

        # Add stage if not already added to this pipeline
        unless stages_hash[pipeline.id][stage.id]
          stages_hash[pipeline.id][stage.id] = {
            id: stage.id,
            name: stage.name,
            position: stage.position,
            color: stage.color
          }
        end

        # Store pipeline_item for the current stage (where the item is currently located)
        # This will be used to calculate days_in_current_stage
        stage_items_map[pipeline.id][stage.id] = item
      end

      # Build final pipelines array with stages sorted by position
      result['pipelines'] = pipelines_hash.values.map do |pipeline_data|
        pipeline_id = pipeline_data[:id]
        stages = stages_hash[pipeline_id].values.sort_by { |s| s[:position] }
        pipeline_data[:stages] = stages.map do |stage_data|
          stage_id = stage_data[:id]
          stage_item = stage_items_map[pipeline_id][stage_id]

          stage_result = {
            id: stage_data[:id],
            name: stage_data[:name],
            color: stage_data[:color]
          }

          # Add days_in_current_stage if pipeline_item exists for this stage
          if stage_item
            stage_result[:days_in_current_stage] = stage_item.days_in_current_stage
          end

          stage_result
        end
        pipeline_data
      end
    else
      # If pipeline_items are not loaded, ensure pipelines key exists as empty array
      result['pipelines'] = []
    end

    # Conditionally include messages (expensive operation)
    if include_messages
      result['messages'] = conversation.messages.map do |message|
        MessageSerializer.serialize(message)
      end
    end

    last_non_activity_message = if last_non_activity_messages
      last_non_activity_messages[conversation.id]
    else
      conversation.messages.last
    end

    if last_non_activity_message
      result['last_non_activity_message'] = {
        id: last_non_activity_message.id,
        content: last_non_activity_message.content,
        message_type: last_non_activity_message.message_type,
        created_at: last_non_activity_message.created_at&.iso8601,
        processed_message_content: last_non_activity_message.processed_message_content,
        sender: last_non_activity_message.sender ? {
          id: last_non_activity_message.sender.id,
          name: last_non_activity_message.sender.name,
          type: last_non_activity_message.sender_type
        } : nil
      }
    end

    result
  end

  # Serialize collection of Conversations
  #
  # @param conversations [Array<Conversation>, ActiveRecord::Relation]
  # @param options [Hash] Same options as serialize method
  #
  # @return [Array<Hash>] Array of serialized conversations
  #
  def serialize_collection(conversations, **options)
    return [] unless conversations

    conversations.map { |conversation| serialize(conversation, **options) }
  end
end
