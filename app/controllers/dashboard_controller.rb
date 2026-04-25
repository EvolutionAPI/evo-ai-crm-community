class DashboardController < ActionController::Base
  include SwitchLocale

  before_action :set_application_pack
  before_action :set_global_config
  before_action :set_dashboard_scripts
  around_action :switch_locale
  before_action :ensure_installation_onboarding, only: [:index]
  before_action :render_hc_if_custom_domain, only: [:index]
  before_action :ensure_html_format
  layout 'vueapp'

  def index; end

  private

  def ensure_html_format
    head :not_acceptable unless request.format.html?
  end

  def set_global_config
    @global_config = GlobalConfig.get(
      'LOGO', 'LOGO_DARK', 'LOGO_THUMBNAIL',
      'INSTALLATION_NAME',
      'WIDGET_BRAND_URL', 'TERMS_URL',
      'BRAND_URL', 'BRAND_NAME',
      'PRIVACY_URL',
      'DISPLAY_MANIFEST',
      'CREATE_NEW_ACCOUNT_FROM_DASHBOARD',
      'EVOLUTION_INBOX_TOKEN',
      'API_CHANNEL_NAME',
      'API_CHANNEL_THUMBNAIL',
      'ANALYTICS_TOKEN',
      'DIRECT_UPLOADS_ENABLED',
      'HCAPTCHA_SITE_KEY',
      'LOGOUT_REDIRECT_LINK',
      'DISABLE_USER_PROFILE_UPDATE',
      'DEPLOYMENT_ENV',
    ).merge(app_config).merge(custom_config)
  end

  def custom_config
    {
      'INSTALLATION_NAME' => 'Evolution',
      'BRAND_NAME' => 'Evolution',
      'LOGO' => 'https://evolution-api.com/files/evo/logo-evo-ai.svg',
      'LOGO_DARK' => 'https://evolution-api.com/files/evo/logo-evo-ai-dark.svg',
      'LOGO_THUMBNAIL' => 'https://evolution-api.com/files/evo/favicon.svg',
      'WIDGET_BRAND_URL' => 'https://evo-ai.co',
      'PRIVACY_URL' => 'https://evoapicloud.com/privacy-policy.html',
      'TERMS_URL' => 'https://evoapicloud.com/terms-of-use.html',
      'DISPLAY_MANIFEST' => false
    }
  end

  def set_dashboard_scripts
    @dashboard_scripts = sensitive_path? ? nil : GlobalConfig.get_value('DASHBOARD_SCRIPTS')
  end

  def ensure_installation_onboarding
    redirect_to '/installation/onboarding' if ::Redis::Alfred.get(::Redis::Alfred::EVOLUTION_INSTALLATION_ONBOARDING)
  end

  def render_hc_if_custom_domain
    # Help center is now handled by frontend
    # Custom domain redirects should be handled at reverse proxy/load balancer level
  end

  def app_config
    basic_config.merge(integration_config).merge(platform_config)
  end

  def set_application_pack
    @application_pack = if request.path.include?('/auth') || request.path.include?('/login')
                          'v3app'
                        else
                          'dashboard'
                        end
  end

  def sensitive_path?
    # dont load dashboard scripts on sensitive paths like password reset
    # edit_user_password_path moved to evo-auth-service
    sensitive_paths = [].freeze

    # remove app prefix
    current_path = request.path.gsub(%r{^/app}, '')

    sensitive_paths.include?(current_path)
  end

  def basic_config
    {
      APP_VERSION: Evolution.config[:version],
      VAPID_PUBLIC_KEY: VapidService.public_key,
      ENABLE_ACCOUNT_SIGNUP: GlobalConfigService.load('ENABLE_ACCOUNT_SIGNUP', 'false'),
      GIT_SHA: GIT_HASH
    }
  end

  def integration_config
    {
      FB_APP_ID: GlobalConfigService.load('FB_APP_ID', ''),
      WP_APP_ID: GlobalConfigService.load('WP_APP_ID', ''),
      WP_API_VERSION: GlobalConfigService.load('WP_API_VERSION', 'v23.0'),
      WP_WHATSAPP_CONFIG_ID: GlobalConfigService.load('WP_WHATSAPP_CONFIG_ID', ''),
      INSTAGRAM_APP_ID: GlobalConfigService.load('INSTAGRAM_APP_ID', ''),
      INSTAGRAM_APP_SECRET: GlobalConfigService.load('INSTAGRAM_APP_SECRET', ''),
      FACEBOOK_API_VERSION: GlobalConfigService.load('FACEBOOK_API_VERSION', 'v17.0')
    }
  end

  def platform_config
    # TODO: [Story 1.4] _SECRET values are exposed as plaintext to frontend here.
    # Replace with boolean presence checks or masked values once admin controller is built.
    {
      EVOLUTION_API_URL: GlobalConfigService.load('EVOLUTION_API_URL', ''),
      EVOLUTION_ADMIN_SECRET: GlobalConfigService.load('EVOLUTION_ADMIN_SECRET', ''),
      EVOLUTION_GO_API_URL: GlobalConfigService.load('EVOLUTION_GO_API_URL', ''),
      EVOLUTION_GO_ADMIN_SECRET: GlobalConfigService.load('EVOLUTION_GO_ADMIN_SECRET', ''),
      OPENAI_API_URL: GlobalConfigService.load('OPENAI_API_URL', ''),
      OPENAI_API_SECRET: GlobalConfigService.load('OPENAI_API_SECRET', ''),
      OPENAI_MODEL: GlobalConfigService.load('OPENAI_MODEL', 'gpt-4.1-nano'),
      AZURE_APP_ID: GlobalConfigService.load('AZURE_APP_ID', ''),
      GOOGLE_OAUTH_CLIENT_ID: GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', ''),
      GOOGLE_OAUTH_CLIENT_SECRET: GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_SECRET', ''),
      GOOGLE_OAUTH_CALLBACK_URL: GlobalConfigService.load('GOOGLE_OAUTH_CALLBACK_URL', ''),
      BMS_API_SECRET: GlobalConfigService.load('BMS_API_SECRET', ''),
      BMS_IPPOOL: GlobalConfigService.load('BMS_IPPOOL', ''),
      FIREBASE_PROJECT_ID: GlobalConfigService.load('FIREBASE_PROJECT_ID', ''),
      FIREBASE_CREDENTIALS_SECRET: GlobalConfigService.load('FIREBASE_CREDENTIALS_SECRET', '')
    }
  end
end
