module Whatsapp::EvolutionGoHandlers::ProfilePictureHandler
  include Whatsapp::EvolutionGoHandlers::Helpers

  private

  def update_contact_profile_picture(contact, phone_number)
    return if contact.avatar.attached?
    return unless channel_evolution_go_configured?

    # Determine primary and fallback numbers for avatar fetch
    primary_number, fallback_number = determine_avatar_fetch_numbers(contact, phone_number)

    Rails.logger.info "Evolution Go API: Scheduling avatar fetch for contact #{contact.id} (primary: #{primary_number}, fallback: #{fallback_number})"

    EvolutionGo::FetchContactAvatarWithFallbackJob.perform_later(
      contact.id,
      primary_number,
      fallback_number,
      api_base_url,
      instance_token
    )
  rescue StandardError => e
    Rails.logger.error "Evolution Go API: Failed to schedule avatar fetch for contact #{contact.id}: #{e.message}"
  end

  def determine_avatar_fetch_numbers(contact, phone_number)
    # If contact has identifier (SenderAlt), use it as primary and phone_number as fallback
    if contact.identifier.present?
      primary = contact.identifier
      fallback = phone_number
      Rails.logger.info "Evolution Go API: Using identifier '#{primary}' as primary, phone '#{fallback}' as fallback"
    else
      # No identifier available, use phone_number as primary only
      primary = phone_number
      fallback = nil
      Rails.logger.info "Evolution Go API: Using phone '#{primary}' as primary (no identifier available)"
    end

    [primary, fallback]
  end

  def channel_evolution_go_configured?
    api_base_url.present? && instance_token.present?
  end

  # Channel configuration: prefer channel-level URL; fall back to admin global
  # so canais criados antes da config global existir continuem funcionando.
  def api_base_url
    @api_base_url ||= whatsapp_channel.provider_config['api_url'].presence ||
                      GlobalConfigService.load('EVOLUTION_GO_API_URL', '')
  end

  def admin_token
    @admin_token ||= whatsapp_channel.provider_config['admin_token'].presence ||
                     GlobalConfigService.load('EVOLUTION_GO_ADMIN_SECRET', '')
  end

  def instance_token
    @instance_token ||= whatsapp_channel.provider_config['instance_token']
  end
end
