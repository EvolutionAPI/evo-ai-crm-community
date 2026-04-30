# Builder for creating messages from Facebook post comments
class Messages::Facebook::CommentBuilder
  attr_reader :parser, :inbox, :conversation

  def initialize(parser, inbox, conversation)
    @parser = parser
    @inbox = inbox
    @conversation = conversation
  end

  def perform
    return if inbox.channel.reauthorization_required?

    ActiveRecord::Base.transaction do
      build_contact_inbox
      build_message
    end
  rescue Koala::Facebook::AuthenticationError => e
    Rails.logger.warn("Facebook authentication error for inbox: #{@inbox.id} with error: #{e.message}")
    Rails.logger.error e
    @inbox.channel.authorization_error!
  rescue StandardError => e
    EvolutionExceptionTracker.new(e, account: nil).capture_exception
    true
  end

  private

  def build_contact_inbox
    # Always create or find contact for the comment author
    # Each commenter has their own contact, but all comments go to the same conversation (identified by post_id)
    @contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: parser.from_id,
      inbox: inbox,
      contact_attributes: contact_params
    ).perform
    Rails.logger.info("CommentBuilder: Created/found contact_inbox: #{@contact_inbox.id} for user #{parser.from_id}")
  end

  def build_message
    message_content = parser.message
    Rails.logger.info("CommentBuilder: Creating message with content: #{message_content.inspect}")
    Rails.logger.info("CommentBuilder: Parser change_value keys: #{parser.change_value.keys.join(', ')}")
    Rails.logger.info("CommentBuilder: Full change_value: #{parser.change_value.to_json}")

    @message = conversation.messages.create!(message_params)

    # Link reply to parent message if this is a reply to another comment
    link_reply_to_parent if in_reply_to_external_id.present?
  end

  def in_reply_to_external_id
    @in_reply_to_external_id ||= begin
      parent_id = parser.parent_id
      post_id = parser.post_id

      Rails.logger.info("CommentBuilder: Checking reply - parent_id: #{parent_id.inspect}, post_id: #{post_id.inspect}")

      if parent_id.present? && parent_id != post_id
        Rails.logger.info("CommentBuilder: This is a reply to comment #{parent_id}")
        parent_id
      else
        Rails.logger.info("CommentBuilder: This is NOT a reply (parent_id: #{parent_id.inspect}, post_id: #{post_id.inspect})")
        nil
      end
    end
  end

  def link_reply_to_parent
    Messages::InReplyToMessageBuilder.new(
      message: @message,
      in_reply_to: nil,
      in_reply_to_external_id: in_reply_to_external_id
    ).perform

    @message.save! if @message.changed?
  end

  def message_params
    message_content = parser.message

    # If message is blank, try to fetch from Facebook API
    if message_content.blank? && parser.comment_id.present?
      Rails.logger.warn("CommentBuilder: Message content is blank, attempting to fetch from Facebook API")
      message_content = fetch_comment_content_from_api
    end

    # Calculate in_reply_to_external_id before creating message
    reply_external_id = in_reply_to_external_id
    Rails.logger.info("CommentBuilder: message_params - in_reply_to_external_id: #{reply_external_id.inspect}")

    {
      inbox_id: conversation.inbox_id,
      message_type: :incoming,
      content: message_content,
      source_id: parser.comment_id,
      content_attributes: {
        in_reply_to_external_id: reply_external_id,
        post_id: parser.post_id,
        comment_id: parser.comment_id,
        is_boosted_post: parser.is_boosted?
      },
      sender: @contact_inbox.contact
    }
  end

  def fetch_comment_content_from_api
    return nil unless inbox.channel.is_a?(Channel::FacebookPage)

    begin
      graph = Koala::Facebook::API.new(inbox.channel.page_access_token)
      comment = graph.get_object(parser.comment_id, fields: 'message')
      comment['message']
    rescue StandardError => e
      Rails.logger.error("CommentBuilder: Failed to fetch comment from API: #{e.message}")
      nil
    end
  end

  def contact_params
    {
      name: parser.from_name || "Facebook User #{parser.from_id[0..10]}",
      additional_attributes: {
        facebook_user_id: parser.from_id
      }
    }
  end
end

