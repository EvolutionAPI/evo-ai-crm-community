# frozen_string_literal: true

# MessageSerializer - Optimized serialization for Message resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   MessageSerializer.serialize(@message, include_attachments: true)
#
module MessageSerializer
  extend self

  # Serialize single Message with optimized field selection
  #
  # @param message [Message] Message to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_attachments Include attachments
  # @option options [Boolean] :include_sender Include sender details
  # @option options [Boolean] :include_conversation Include conversation summary
  #
  # @return [Hash] Serialized message ready for Oj
  #
  def serialize(message, include_attachments: true, include_sender: true, include_conversation: false)
    result = message.as_json(
      only: [:id, :content, :content_type, :content_attributes, :message_type,
             :private, :status, :source_id, :sender_type, :sender_id,
             :conversation_id, :external_source_ids,
             :additional_attributes, :processed_message_content, :sentiment, :sentiment_score]
    )

    # EVO-1551 round 6 — route through Message#content_attributes_for_egress
    # so the masker is the single source of truth for every server boundary.
    # Per-request audience: admin tier sees raw via `should_mask?`.
    result['content_attributes'] = message.content_attributes_for_egress(audience: :per_request)

    # Timestamps
    result['created_at'] = message.created_at.to_i
    result['updated_at'] = message.updated_at&.to_i

    # Include sender (identifies who sent the message: agent, bot, or contact)
    if include_sender
      sender_type = resolve_sender_type(message.sender_type)
      contact_sender = message.sender_type.to_s.casecmp('contact').zero?
      mask_contact_sender = contact_sender && ContactPiiMasker.should_mask?

      if message.association(:sender).loaded? && message.sender.present?
        sender = message.sender
        sender_name = sender.try(:name) ||
                      sender.try(:available_name) ||
                      sender.try(:email) ||
                      ''
        sender_name = ContactPiiMasker.mask_phone_like_name(sender_name) if mask_contact_sender
        result['sender'] = {
          id: sender.id.to_s,
          name: sender_name,
          type: sender_type,
          thumbnail: sender.try(:avatar_url),
          avatar_url: sender.try(:avatar_url)
        }
      elsif message.sender.present?
        # Sender not loaded, but exists - load it
        sender = message.sender
        sender_name = sender.try(:name) ||
                      sender.try(:available_name) ||
                      sender.try(:email) ||
                      ''
        sender_name = ContactPiiMasker.mask_phone_like_name(sender_name) if mask_contact_sender
        result['sender'] = {
          id: sender.id.to_s,
          name: sender_name,
          type: sender_type,
          thumbnail: sender.try(:avatar_url),
          avatar_url: sender.try(:avatar_url)
        }
      else
        # Provide default sender if missing
        result['sender'] = {
          id: message.sender_id&.to_s || '',
          name: '',
          type: sender_type,
          thumbnail: nil,
          avatar_url: nil
        }
      end
    end

    # Include conversation
    if include_conversation && message.conversation.present?
      result['conversation'] = {
        id: message.conversation.id,
        display_id: message.conversation.display_id
      }
    end

    # Always include attachments array (frontend requires it, even if empty)
    if include_attachments
      result['attachments'] = if message.association(:attachments).loaded? || message.attachments.loaded?
        message.attachments.map do |attachment|
          serialize_attachment(attachment)
        end
      else
        # If attachments not loaded, load them
        message.attachments.map do |attachment|
          serialize_attachment(attachment)
        end
      end
    else
      result['attachments'] = []
    end

    result
  end
  
  def serialize_attachment(attachment)
    file_size = if attachment.file.attached? && attachment.file.blob.present?
      attachment.file.blob.byte_size
    else
      0
    end

    {
      id: attachment.id.to_s,
      message_id: attachment.message_id&.to_s || attachment.attachable_id.to_s,
      file_type: attachment.file_type,
      extension: attachment.extension,
      data_url: attachment.file_url || '',
      thumb_url: attachment.thumb_url,
      file_size: file_size,
      fallback_title: attachment.fallback_title,
      coordinates_lat: attachment.coordinates_lat || 0,
      coordinates_long: attachment.coordinates_long || 0,
      external_url: attachment.external_url,
      transcribed_text: attachment.meta&.dig('transcribed_text'),
      meta: attachment.meta || {}
    }
  end

  # Serialize collection of Messages
  #
  # @param messages [Array<Message>, ActiveRecord::Relation]
  # @param options [Hash] Same options as serialize method
  #
  # @return [Array<Hash>] Array of serialized messages
  #
  # Normalize sender_type from Rails class name to frontend-expected format.
  # DB stores 'AgentBot' but frontend expects 'agent_bot' to render bot styling.
  def resolve_sender_type(raw_type)
    return 'user' if raw_type.blank?

    raw_type == 'AgentBot' ? 'agent_bot' : raw_type.to_s
  end

  def serialize_collection(messages, **options)
    return [] unless messages

    messages.map { |message| serialize(message, **options) }
  end
end
