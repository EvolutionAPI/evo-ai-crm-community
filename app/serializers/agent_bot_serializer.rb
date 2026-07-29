# frozen_string_literal: true

module AgentBotSerializer
  extend self

  def serialize(agent_bot, agent_bot_inbox: nil)
    return nil unless agent_bot

    agent_bot_data = {
      id: agent_bot.id,
      name: agent_bot.name,
      description: agent_bot.description,
      outgoing_url: agent_bot.outgoing_url,
      bot_type: agent_bot.bot_type,
      bot_provider: agent_bot.bot_provider,
      bot_config: agent_bot.bot_config || {},
      # The reference is an id, not a secret: the screen needs it to show which
      # vault credential the bot uses. `api_key` stays out, as it always was.
      credential_id: agent_bot.credential_id,
      avatar_url: agent_bot.avatar_url,
      message_signature: agent_bot.message_signature,
      text_segmentation_enabled: agent_bot.text_segmentation_enabled,
      text_segmentation_limit: agent_bot.text_segmentation_limit,
      text_segmentation_min_size: agent_bot.text_segmentation_min_size,
      delay_per_character: agent_bot.delay_per_character,
      debounce_time: agent_bot.debounce_time,
      created_at: agent_bot.created_at&.iso8601,
      updated_at: agent_bot.updated_at&.iso8601
    }

    # If agent_bot_inbox is provided, return structure with agent_bot and configuration
    if agent_bot_inbox
      {
        agent_bot: agent_bot_data,
        configuration: serialize_agent_bot_inbox_configuration(agent_bot_inbox)
      }
    else
      agent_bot_data
    end
  end

  def serialize_collection(agent_bots)
    return [] unless agent_bots

    agent_bots.map { |bot| serialize(bot) }
  end

  private

  def serialize_agent_bot_inbox_configuration(agent_bot_inbox)
    return nil unless agent_bot_inbox

    {
      allowed_conversation_statuses: agent_bot_inbox.allowed_conversation_statuses || [],
      allowed_label_ids: agent_bot_inbox.allowed_label_ids || [],
      ignored_label_ids: agent_bot_inbox.ignored_label_ids || [],
      facebook_comment_replies_enabled: agent_bot_inbox.facebook_comment_replies_enabled || false,
      facebook_comment_agent_bot_id: agent_bot_inbox.facebook_comment_agent_bot_id,
      facebook_interaction_type: agent_bot_inbox.facebook_interaction_type || 'both',
      facebook_allowed_post_ids: agent_bot_inbox.facebook_allowed_post_ids || [],
      moderation_enabled: agent_bot_inbox.moderation_enabled || false,
      explicit_words_filter: agent_bot_inbox.explicit_words_filter || [],
      sentiment_analysis_enabled: agent_bot_inbox.sentiment_analysis_enabled || false,
      auto_approve_responses: agent_bot_inbox.auto_approve_responses || false,
      auto_reject_explicit_words: agent_bot_inbox.auto_reject_explicit_words || false,
      auto_reject_offensive_sentiment: agent_bot_inbox.auto_reject_offensive_sentiment || false
    }
  end
end
