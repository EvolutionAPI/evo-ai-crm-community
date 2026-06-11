# frozen_string_literal: true

# Locates the MessageTemplate to use when SENDING a message, bridging the
# id-based (new, global-aware) and the legacy name-based lookup paths.
#
# Resolution order:
#   1. By id (canonical) — returns the record only when it is global
#      (channel_id/channel_type both nil) or visible to the given channel.
#   2. By name + language — channel-bound first, then the global bucket.
#
# Rendering stays the caller's job (MessageTemplate#render_with_variables);
# this class only locates and returns nil on a miss.
#
# Named SendResolver to avoid confusion with MessageTemplate.resolver, which
# delegates to EmailTemplates::DbResolverService for a different concern.
class MessageTemplates::SendResolver
  DEFAULT_LANGUAGE = 'pt_BR'

  def initialize(id: nil, name: nil, language: nil, channel: nil)
    @id = id.presence
    @name = name.presence
    @language = language.presence || DEFAULT_LANGUAGE
    @channel = channel
  end

  def resolve
    @id ? resolve_by_id : resolve_by_name
  end

  private

  def resolve_by_id
    template = MessageTemplate.active.find_by(id: @id)
    return nil if template.nil?
    return template if global?(template) || visible_to_channel?(template)

    # An id that resolves to a different channel (or a different channel TYPE)
    # is not visible to this caller — treat it as a miss.
    nil
  end

  def resolve_by_name
    return nil if @name.blank?

    channel_match = @channel&.message_templates&.active&.find_by(name: @name, language: @language)
    return channel_match if channel_match

    MessageTemplate.where(channel_id: nil).active.find_by(name: @name, language: @language)
  end

  def global?(template)
    template.channel_id.nil? && template.channel_type.nil?
  end

  def visible_to_channel?(template)
    return false if @channel.nil?

    template.channel_type == @channel.class.name && template.channel_id == @channel.id
  end
end
