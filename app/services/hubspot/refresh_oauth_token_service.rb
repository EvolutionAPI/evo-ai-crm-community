# Service to handle HubSpot OAuth token refresh
# HubSpot tokens expire after a certain period and need to be refreshed using refresh_token
class Hubspot::RefreshOauthTokenService
  attr_reader :hook

  def initialize(hook:)
    @hook = hook
  end

  # Returns a valid access token, refreshing it if necessary
  def access_token
    return hook.access_token unless token_expired?

    refresh_token
  end

  private

  # Checks if the current token is expired
  def token_expired?
    return true if hook.settings['expires_at'].blank?

    # Add 5 minute buffer to avoid race conditions
    Time.current >= Time.parse(hook.settings['expires_at']) - 5.minutes
  rescue ArgumentError
    true # If expires_at is malformed, consider it expired
  end

  # Refreshes the OAuth token using the refresh_token
  def refresh_token
    return hook.access_token if hook.settings['refresh_token'].blank?

    apply_refresh_response(make_refresh_request)
  rescue StandardError => e
    # The stale token is still returned: the caller contract is "give me a
    # token", and failing here would break the conversation in progress. What
    # changed is that the failure stops being invisible.
    #
    # `authorization_error!` is the mechanism this codebase already has for
    # "tell the human": it counts failures in Redis and, past the threshold,
    # e-mails and deactivates the hook. Bypassing it is what let an integration
    # stay dead for days with nothing but a log line (EVO-2250).
    Rails.logger.error("HubSpot token refresh failed for hook #{hook.id}: #{e.class}: #{e.message}")
    report_authorization_error
    hook.access_token
  end

  def apply_refresh_response(response)
    parsed_response = JSON.parse(response.body)
    raise "HubSpot token refresh failed: #{parsed_response['message'] || response.body}" unless response.success?

    update_hook_tokens(parsed_response)
    hook.reload.access_token
  end

  # Never let the reporting itself take down the refresh: a Redis hiccup must
  # not turn a recoverable stale-token path into an exception.
  def report_authorization_error
    hook.authorization_error!
  rescue StandardError => e
    Rails.logger.error("HubSpot token refresh could not report the failure: #{e.class}: #{e.message}")
  end

  def make_refresh_request
    endpoint = 'https://api.hubapi.com/oauth/v1/token'

    params = {
      grant_type: 'refresh_token',
      refresh_token: hook.settings['refresh_token'],
      client_id: GlobalConfigService.load('HUBSPOT_CLIENT_ID', nil),
      client_secret: GlobalConfigService.load('HUBSPOT_CLIENT_SECRET', nil)
    }

    HTTParty.post(
      endpoint,
      body: URI.encode_www_form(params),
      headers: {
        'Content-Type' => 'application/x-www-form-urlencoded',
        'Accept' => 'application/json'
      }
    )
  end

  def update_hook_tokens(token_data)
    new_settings = hook.settings.merge(
      'expires_at' => (Time.current + token_data['expires_in'].seconds).to_s,
      'refresh_token' => token_data['refresh_token']
    )

    hook.update!(
      access_token: token_data['access_token'],
      settings: new_settings
    )
  end
end
