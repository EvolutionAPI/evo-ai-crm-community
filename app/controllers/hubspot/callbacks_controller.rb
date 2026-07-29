class Hubspot::CallbacksController < ApplicationController
  include Hubspot::IntegrationHelper

  def show
    Rails.logger.info("HubSpot callback started with state: #{params[:state]}")

    # Manual token exchange with explicit headers
    token_params = {
      grant_type: 'authorization_code',
      client_id: GlobalConfigService.load('HUBSPOT_CLIENT_ID', nil),
      client_secret: GlobalConfigService.load('HUBSPOT_CLIENT_SECRET', nil),
      redirect_uri: "#{base_url}/hubspot/callback",
      code: params[:code]
    }

    # ⚠️ NEVER render token_params: it carries the installation's client_secret
    # and the one-time authorization code. Logging the hash wrote the app secret
    # in cleartext to every log sink, on every OAuth connection (EVO-2250).
    Rails.logger.info("Token exchange starting for redirect_uri #{token_params[:redirect_uri]}")

    token_response = oauth_client.request(:post, '/oauth/v1/token', {
      body: URI.encode_www_form(token_params),
      headers: {
        'Content-Type' => 'application/x-www-form-urlencoded'
      }
    })

    Rails.logger.info("Token exchange successful")
    @response_body = JSON.parse(token_response.body)
    handle_response
  rescue StandardError => e
    Rails.logger.error("HubSpot callback error: #{e.message}")
    Rails.logger.error("Error details: #{e.response.body if e.respond_to?(:response) && e.response}")
    redirect_to hubspot_redirect_uri
  end

  private

  def oauth_client
    app_id = GlobalConfigService.load('HUBSPOT_CLIENT_ID', nil)
    app_secret = GlobalConfigService.load('HUBSPOT_CLIENT_SECRET', nil)

    Rails.logger.info("OAuth client - app_id: #{app_id}")
    Rails.logger.info("OAuth client - app_secret present: #{app_secret.present?}")

    OAuth2::Client.new(
      app_id,
      app_secret,
      {
        site: 'https://api.hubapi.com',
        token_url: 'https://api.hubapi.com/oauth/v1/token',
        authorize_url: 'https://app.hubspot.com/oauth/authorize'
      }
    )
  end

  def handle_response
    # Get HubSpot portal info
    portal_info = get_portal_info(parsed_body['access_token'])

    hook = Hook.new(
      access_token: parsed_body['access_token'],
      status: 'enabled',
      app_id: 'hubspot',
      settings: {
        refresh_token: parsed_body['refresh_token'],
        token_type: parsed_body['token_type'],
        expires_in: parsed_body['expires_in'],
        scope: parsed_body['scope'],
        portal_id: portal_info['hub_id']
      }
    )

    hook.save!
    redirect_to hubspot_redirect_uri
  rescue StandardError => e
    Rails.logger.error("HubSpot callback error: #{e.message}")
    redirect_to hubspot_redirect_uri
  end

  def get_portal_info(access_token)
    # Get portal information from HubSpot API
    conn = Faraday.new('https://api.hubapi.com') do |f|
      f.adapter Faraday.default_adapter
    end

    response = conn.get('/account-info/v3/api-usage/daily') do |req|
      req.headers['Authorization'] = "Bearer #{access_token}"
    end

    if response.success?
      JSON.parse(response.body)
    else
      # Fallback - use a different endpoint
      response = conn.get('/oauth/v1/access-tokens/' + access_token)
      JSON.parse(response.body)
    end
  rescue StandardError => e
    Rails.logger.error("Error getting HubSpot portal info: #{e.message}")
    { 'hub_id' => 'unknown' }
  end

  def hubspot_redirect_uri
    "#{ENV.fetch('FRONTEND_URL', nil)}/app/settings/integrations/hubspot"
  end

  def parsed_body
    @response_body
  end

  def base_url
    ENV.fetch('FRONTEND_URL', 'http://localhost:3000')
  end
end
