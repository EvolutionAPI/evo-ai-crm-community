require 'cgi'

class Integrations::App
  include Linear::IntegrationHelper
  include Hubspot::IntegrationHelper
  include GoogleConcern
  attr_accessor :params

  def initialize(params)
    @params = params
  end

  def id
    params[:id]
  end

  def name
    I18n.t("integration_apps.#{params[:i18n_key]}.name")
  end

  def description
    I18n.t("integration_apps.#{params[:i18n_key]}.description")
  end

  def short_description
    I18n.t("integration_apps.#{params[:i18n_key]}.short_description")
  end

  def logo
    params[:logo]
  end

  def fields
    params[:fields]
  end

  # Token generation is used to encode an identifier in the OAuth state parameter
  def encode_state
    case params[:id]
    when 'linear'
      generate_linear_token(nil)
    when 'hubspot'
      generate_hubspot_token(nil)
    when 'google_workspace'
      generate_google_token('google_workspace')
    when 'google_ads'
      generate_google_token('google_ads')
    else
      nil
    end
  end

  def action
    case params[:id]
    when 'slack'
      client_id = GlobalConfigService.load('SLACK_CLIENT_ID', nil)
      "#{params[:action]}&client_id=#{client_id}&redirect_uri=#{self.class.slack_integration_url}"
    when 'linear'
      build_linear_action
    when 'hubspot'
      build_hubspot_action
    when 'google_workspace'
      build_google_workspace_action
    when 'google_ads'
      build_google_ads_action
    else
      params[:action]
    end
  end

  def active?(_account = nil)
    case params[:id]
    when 'slack'
      GlobalConfigService.load('SLACK_CLIENT_SECRET', nil).present?
    when 'linear'
      GlobalConfigService.load('LINEAR_CLIENT_ID', nil).present?
    when 'hubspot'
      GlobalConfigService.load('HUBSPOT_CLIENT_ID', nil).present?
    when 'shopify'
      GlobalConfigService.load('SHOPIFY_CLIENT_ID', nil).present?
    when 'leadsquared', 'bms'
      true
    when 'webhook', 'dashboard_apps', 'openai', 'gemini', 'google_workspace', 'groq', 'google_ads', 'elevenlabs', 'huggingface'
      true
    when 'oauth_applications'
      false
    else
      false
    end
  end

  def build_linear_action
    app_id = GlobalConfigService.load('LINEAR_CLIENT_ID', nil)
    [
      "#{params[:action]}?response_type=code",
      "client_id=#{app_id}",
      "redirect_uri=#{self.class.linear_integration_url}",
      "state=#{encode_state}",
      'scope=read,write',
      'prompt=consent'
    ].join('&')
  end

  def build_hubspot_action
    app_id = GlobalConfigService.load('HUBSPOT_CLIENT_ID', nil)
    [
      "#{params[:action]}?response_type=code",
      "client_id=#{app_id}",
      "redirect_uri=#{self.class.hubspot_integration_url}",
      "state=#{encode_state}",
      'scope=crm.objects.contacts.read crm.objects.contacts.write crm.objects.deals.read crm.objects.deals.write crm.objects.companies.read crm.objects.companies.write crm.objects.line_items.read crm.objects.owners.read crm.schemas.deals.read oauth settings.users.read'
    ].join('&')
  end

  # Drive/GTM/Ads leitura, além de email/profile pra identificar a conta
  # conectada. access_type=offline + prompt=consent garantem o refresh_token
  # (sem isso o Google só devolve um access_token de curta duração). Retorna
  # nil enquanto o Client ID/Secret não tiverem sido cadastrados — a
  # serialização usa .compact, então o card aparece sem `action` e o
  # frontend mostra a tela de configuração em vez de tentar redirecionar
  # pro Google.
  def build_google_workspace_action
    client_id = GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil)
    return nil unless client_id.present?

    # Escopos de escrita do GTM (edição de tags/acionadores/variáveis/pastas,
    # criação de contêineres, versões e gerenciamento de usuários/permissões)
    # substituem o antigo tagmanager.readonly — uma reconexão (prompt=consent)
    # é necessária pra quem já tinha autorizado só leitura.
    #
    # `analytics.readonly` foi adicionado pro relatório de Google Analytics
    # (dashboard de relatórios, ver Google::AnalyticsInsightsService) — dá
    # pra reaproveitar esta mesma conexão porque a Data API do GA4 só exige
    # OAuth normal, sem developer token (diferente do Google Ads: essa API
    # tem token de desenvolvedor à parte, por isso usa uma credencial própria
    # em Integrations::Hook(app_id: 'google_ads'), não esta conexão).
    scope = [
      'email',
      'profile',
      'https://www.googleapis.com/auth/drive.readonly',
      'https://www.googleapis.com/auth/tagmanager.edit.containers',
      'https://www.googleapis.com/auth/tagmanager.edit.containerversions',
      'https://www.googleapis.com/auth/tagmanager.delete.containers',
      'https://www.googleapis.com/auth/tagmanager.manage.accounts',
      'https://www.googleapis.com/auth/tagmanager.manage.users',
      'https://www.googleapis.com/auth/tagmanager.publish',
      'https://www.googleapis.com/auth/analytics.readonly',
      # analytics.edit — pro Setup GA4 (Google::Ga4InfrastructureService):
      # criar conta/propriedade/stream, ativar Enhanced Measurement,
      # dimensões, eventos de conversão, link com Google Ads e secret do
      # Measurement Protocol. Precisa reconectar (prompt=consent) pra quem
      # só tinha autorizado analytics.readonly antes.
      'https://www.googleapis.com/auth/analytics.edit',
      # youtube.upload — pro Gestor de Posts subir vídeo pro canal do
      # YouTube conectado (ver Youtube::UploadService). youtube.readonly —
      # pra listar canal/vídeos existentes na galeria (ver
      # Youtube::GalleryService); upload sozinho não é suficiente pra
      # channels.list/playlistItems.list, retorna insufficientPermissions.
      # Mesma reconexão necessária pra quem já autorizou antes sem esses
      # escopos.
      'https://www.googleapis.com/auth/youtube.upload',
      'https://www.googleapis.com/auth/youtube.readonly',
      # calendar — pra ferramenta de Calendário em Meu Espaço (Google::CalendarService)
      # sincronizar/criar eventos de verdade. Reaproveita esta mesma conexão
      # (mesmo Client ID do Google Cloud já usado pra GTM/GA4/YouTube) em vez
      # de um app OAuth separado — precisa reconectar (prompt=consent) pra
      # quem já tinha autorizado antes sem esse escopo.
      'https://www.googleapis.com/auth/calendar'
    ].join(' ')

    [
      "#{params[:action]}?response_type=code",
      "client_id=#{client_id}",
      "redirect_uri=#{CGI.escape(self.class.google_workspace_integration_url)}",
      "scope=#{CGI.escape(scope)}",
      "state=#{encode_state}",
      'access_type=offline',
      'prompt=consent'
    ].join('&')
  end

  # Google Ads reaproveita o MESMO app OAuth do Google (GOOGLE_OAUTH_CLIENT_ID/
  # SECRET, o app já usado por google_workspace) em vez de pedir um client_id/
  # secret/refresh_token à parte por conta — o usuário só faz login com o
  # Google e escolhe a conta de anúncios depois (ver
  # Api::V1::Integrations::GoogleAdsAuthorizationsController). O
  # developer_token continua obrigatório (exigência própria da Google Ads API,
  # não tem como vir do login), mas é uma credencial única do sistema
  # (GlobalConfig GOOGLE_ADS_DEVELOPER_TOKEN), não uma por conta.
  #
  # redirect_uri é a MESMA já cadastrada pro google_workspace (não uma nova) —
  # Api::V1::Integrations::GoogleWorkspaceAuthorizationsController#callback
  # olha o identifier decodificado do state (não a URL) pra saber que é um
  # login de Ads e salvar no hook certo. Evita ter que cadastrar mais uma
  # "Authorized redirect URI" no Google Cloud Console.
  def build_google_ads_action
    client_id = GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil)
    return nil unless client_id.present?

    scope = ['email', 'profile', 'https://www.googleapis.com/auth/adwords'].join(' ')

    [
      "#{params[:action]}?response_type=code",
      "client_id=#{client_id}",
      "redirect_uri=#{CGI.escape(self.class.google_workspace_integration_url)}",
      "scope=#{CGI.escape(scope)}",
      "state=#{encode_state}",
      'access_type=offline',
      'prompt=consent'
    ].join('&')
  end

  def enabled?(_account = nil)
    case params[:id]
    when 'webhook'
      Webhook.exists?
    when 'dashboard_apps'
      DashboardApp.exists?
    when 'oauth_applications'
      OauthApplication.exists?
    else
      Integrations::Hook.exists?(app_id: id)
    end
  end

  def hooks
    Integrations::Hook.where(app_id: id)
  end

  def self.slack_integration_url
    "#{ENV.fetch('FRONTEND_URL', nil)}/app/settings/integrations/slack"
  end

  def self.linear_integration_url
    "#{ENV.fetch('FRONTEND_URL', nil)}/linear/callback"
  end

  def self.hubspot_integration_url
    "#{ENV.fetch('FRONTEND_URL', nil)}/hubspot/callback"
  end

  def self.google_workspace_integration_url
    "#{ENV.fetch('FRONTEND_URL', nil)}/settings/integrations/google-workspace/callback"
  end

  class << self
    def apps
      Hashie::Mash.new(APPS_CONFIG)
    end

    def all
      apps.values.each_with_object([]) do |app, result|
        result << new(app)
      end
    end

    def find(params)
      all.detect { |app| app.id == params[:id] }
    end
  end
end
