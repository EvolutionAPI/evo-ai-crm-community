# frozen_string_literal: true

class Api::V1::GlobalConfigController < Api::BaseController
  # Public, read-only config: expose only non-sensitive keys used by frontend SDKs/feature gating
  skip_before_action :authenticate_request!

  def show
    render json: public_config
  end

  private

  def public_config
    {
      fbAppId: GlobalConfigService.load('FB_APP_ID', ''),
      fbApiVersion: GlobalConfigService.load('FACEBOOK_API_VERSION', 'v17.0'),
      wpAppId: GlobalConfigService.load('WP_APP_ID', ''),
      wpApiVersion: GlobalConfigService.load('WP_API_VERSION', 'v23.0'),
      wpWhatsappConfigId: GlobalConfigService.load('WP_WHATSAPP_CONFIG_ID', ''),
      instagramAppId: GlobalConfigService.load('INSTAGRAM_APP_ID', nil),
      googleOAuthClientId: GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil),
      azureAppId: GlobalConfigService.load('AZURE_APP_ID', nil),
      # 🔒 SECURITY: Don't expose sensitive API URLs to frontend
      # Frontend only needs to know IF config exists, not the actual values
      hasFacebookConfig: IntegrationRequirements.configured?('facebook'),
      hasWhatsappConfig: IntegrationRequirements.configured?('whatsapp'),
      hasInstagramConfig: IntegrationRequirements.configured?('instagram'),
      hasEvolutionConfig: IntegrationRequirements.configured?('evolution'),
      hasEvolutionGoConfig: IntegrationRequirements.configured?('evolution_go'),
      hasEvolutionHubConfig: IntegrationRequirements.configured?('evolution_hub'),
      evolutionHubEnabled: evolution_hub_active?,
      hubAllowExistingChannels: hub_allow_existing_channels?,
      hasTwitterConfig: IntegrationRequirements.configured?('twitter'),
      openaiConfigured: openai_configured?,
      enableAccountSignup: enable_account_signup?,
      recaptchaSiteKey: GlobalConfigService.load('RECAPTCHA_SITE_KEY', nil),
      clarityProjectId: GlobalConfigService.load('CLARITY_PROJECT_ID', nil),
    }
  end

  def enable_account_signup?
    value = GlobalConfigService.load('ENABLE_ACCOUNT_SIGNUP', 'false')
    normalized_value = value.to_s.strip.downcase
    normalized_value == 'true'
  end

  # Permite a opção "Usar canal existente do Hub" no modal de criação de inbox.
  # DEFAULT true (retrocompat: community standalone mantém o comportamento). No
  # deploy enterprise/SaaS seta-se HUB_ALLOW_EXISTING_CHANNELS=false, pois a
  # listagem de canais existentes do Hub usa credenciais GLOBAIS sem filtro de
  # tenant → vazaria conexões de outras agências. O front esconde a opção e o
  # controller do Hub também 403a available_channels (defesa em profundidade).
  def hub_allow_existing_channels?
    value = GlobalConfigService.load('HUB_ALLOW_EXISTING_CHANNELS', 'true')
    ActiveModel::Type::Boolean.new.cast(value)
  end

  # The credential comes from the registry, so asking
  # GlobalConfigService for the key would report "not configured" on a migrated
  # install and hide AI features that actually work. URL and model stay here:
  # they are consumer config, not credential.
  def openai_configured?
    api_url = GlobalConfigService.load('OPENAI_API_URL', '').to_s.strip
    model = GlobalConfigService.load('OPENAI_MODEL', '').to_s.strip

    api_url.present? && model.present? &&
      Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist).present?
  end

  # Evolution Hub is "active" when both the toggle is on AND the required
  # config keys are populated. The frontend uses this single boolean to
  # decide whether to render OAuth-direct or Hub-relayed Inbox flows.
  def evolution_hub_active?
    enabled = GlobalConfigService.load('EVOLUTION_HUB_ENABLED', 'false').to_s
    ActiveModel::Type::Boolean.new.cast(enabled) && IntegrationRequirements.configured?('evolution_hub')
  end
end
