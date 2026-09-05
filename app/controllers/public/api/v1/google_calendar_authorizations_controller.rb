# Callback do OAuth do Google Calendar — Google redireta direto pra cá (sem
# passar pelo frontend, ao contrário do fluxo de google_workspace) porque
# não há usuário/sessão de CRM envolvido: é uma credencial global única da
# instalação, igual todas as outras (Meta, Google Ads etc.). Isso evita
# precisar de uma página nova no frontend só pra repassar o `code`.
#
# redirect_uri precisa estar cadastrado em "Authorized redirect URIs" do
# client OAuth (Google Cloud Console) EXATAMENTE como `callback_url` monta
# aqui, e GOOGLE_CALENDAR_REDIRECT_URI (Configurações > Admin) precisa ter
# esse mesmo valor — é o que Integrations::App usaria pra montar o link de
# "Conectar", mas aqui o botão da ferramenta monta a URL direto (client_id
# não é segredo).
class Public::Api::V1::GoogleCalendarAuthorizationsController < PublicController
  def callback
    code = params[:code]
    return render(html: error_page('Código de autorização ausente.').html_safe) if code.blank?

    response = Net::HTTP.post_form(URI('https://oauth2.googleapis.com/token'), {
                                      'code' => code,
                                      'client_id' => GlobalConfigService.load('GOOGLE_CALENDAR_CLIENT_ID', nil),
                                      'client_secret' => GlobalConfigService.load('GOOGLE_CALENDAR_CLIENT_SECRET', nil),
                                      'redirect_uri' => callback_url,
                                      'grant_type' => 'authorization_code'
                                    })
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "GoogleCalendarAuthorizationsController: #{response.code} #{response.body}"
      return render(html: error_page(parsed['error_description'] || parsed['error'] || 'Erro desconhecido').html_safe)
    end

    hook = Integrations::Hook.find_or_initialize_by(app_id: 'google_calendar')
    existing = hook.settings || {}
    hook.settings = existing.merge(
      'access_token' => parsed['access_token'],
      # Google só devolve refresh_token no primeiro consentimento (sem
      # prompt=consent ele vem em branco numa reconexão) — preserva o antigo.
      'refresh_token' => parsed['refresh_token'] || existing['refresh_token'],
      'scope' => parsed['scope'],
      'expires_on' => (Time.current.utc + parsed['expires_in'].to_i.seconds).to_s
    )
    hook.save!

    render html: success_page.html_safe
  rescue StandardError => e
    Rails.logger.error "GoogleCalendarAuthorizationsController: #{e.message}"
    render html: error_page('Erro inesperado ao concluir a conexão.').html_safe
  end

  private

  def callback_url
    "#{request.base_url}/public/api/v1/google_calendar/callback"
  end

  def success_page
    <<~HTML
      <html><body style="font-family:system-ui,sans-serif;text-align:center;padding:60px;background:#0f172a;color:#e2e8f0">
        <h2>✅ Google Calendar conectado!</h2>
        <p>Pode fechar esta aba e voltar pro CRM.</p>
      </body></html>
    HTML
  end

  def error_page(msg)
    <<~HTML
      <html><body style="font-family:system-ui,sans-serif;text-align:center;padding:60px;background:#0f172a;color:#e2e8f0">
        <h2>❌ Erro ao conectar</h2>
        <p>#{ERB::Util.html_escape(msg)}</p>
      </body></html>
    HTML
  end
end
