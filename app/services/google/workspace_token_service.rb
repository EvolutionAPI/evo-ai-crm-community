# Google::WorkspaceTokenService - devolve um access_token válido pra conta
# Google conectada em Configurações > Integrações > Google Login (armazenada
# em Integrations::Hook, app_id: 'google_workspace'). Renova via refresh_token
# quando expirado, igual ao BaseRefreshOauthTokenService usado pros canais de
# e-mail — mas esse serviço guarda em Integrations::Hook#settings, não num
# Channel#provider_config, por isso não reaproveita a classe base diretamente.
class Google::WorkspaceTokenService
  include GoogleConcern

  def access_token
    return nil unless hook

    return settings['access_token'] unless expired?

    refresh!
  end

  def connected?
    hook.present?
  end

  private

  def hook
    @hook ||= Integrations::Hook.find_by(app_id: 'google_workspace')
  end

  def settings
    (hook.settings || {}).with_indifferent_access
  end

  def expired?
    expiry = settings['expires_on']
    return true if expiry.blank?

    Time.current.utc >= DateTime.parse(expiry) - 5.minutes
  end

  def refresh!
    return nil if settings['refresh_token'].blank?

    token = OAuth2::AccessToken.new(
      google_client,
      settings['access_token'],
      refresh_token: settings['refresh_token']
    )
    new_token = token.refresh!

    hook.settings = settings.merge(
      'access_token' => new_token.token,
      'refresh_token' => new_token.refresh_token || settings['refresh_token'],
      'expires_on' => (Time.current.utc + new_token.expires_in.to_i.seconds).to_s
    )
    hook.save!

    new_token.token
  rescue StandardError => e
    Rails.logger.error "Google::WorkspaceTokenService: refresh failed: #{e.message}"
    nil
  end
end
