class Api::V1::Microsoft::AuthorizationsController < Api::V1::BaseController
  require_permissions({
    index: 'microsoft_authorizations.read',
    show: 'microsoft_authorizations.read',
    create: 'microsoft_authorizations.write',
    update: 'microsoft_authorizations.write',
    destroy: 'microsoft_authorizations.delete',
    callback: 'microsoft_authorizations.write'
  })
  include MicrosoftConcern

  def create
    email = params[:authorization][:email]
    state_token = generate_microsoft_token('community')

    redirect_url = microsoft_client.auth_code.authorize_url(
      {
        redirect_uri: "#{base_url}/microsoft/callback",
        scope: 'offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send openid profile',
        prompt: 'consent',
        state: state_token
      }
    )

    if redirect_url
      cache_key = "microsoft::#{email.downcase}"
      ::Redis::Alfred.setex(cache_key, 'community', 5.minutes)
      render json: { success: true, url: redirect_url }
    else
      render json: { success: false }, status: :unprocessable_entity
    end
  end

  def callback
    # Frontend sends the authorization code and state
    code = params[:code]
    state = params[:state]

    unless code && state
      render json: { success: false, error: 'Missing code or state' }, status: :bad_request
      return
    end

    begin
      # Verify state token
      identifier = verify_microsoft_token(state)

      unless identifier
        render json: { success: false, error: 'Invalid or expired state token' }, status: :unauthorized
        return
      end

      # Exchange code for access token
      response = microsoft_client.auth_code.get_token(
        code,
        redirect_uri: "#{base_url}/microsoft/callback"
      )

      # Get user email from Microsoft Graph API
      parsed_body = response.response.parsed
      access_token = parsed_body['access_token']

      # Fetch user profile from Microsoft Graph
      graph_response = HTTParty.get(
        'https://graph.microsoft.com/v1.0/me',
        headers: {
          'Authorization' => "Bearer #{access_token}",
          'Content-Type' => 'application/json'
        }
      )

      users_data = graph_response.parsed
      user_email = users_data['mail'] || users_data['userPrincipalName']

      unless user_email
        raise StandardError, 'Could not retrieve user email from Microsoft Graph'
      end

      channel_email = find_or_create_channel(user_email, users_data, parsed_body)

      # Mark as reauthorized
      channel_email.reauthorized!

      # Clean up cache (if exists)
      cache_key = "microsoft::#{user_email.downcase}"
      ::Redis::Alfred.delete(cache_key)

      render json: {
        success: true,
        inbox_id: channel_email.inbox.id,
        channel_id: channel_email.id,
        email: user_email
      }
    rescue StandardError => e
      Rails.logger.error("Microsoft callback error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def find_or_create_channel(user_email, users_data, parsed_body)
    # Try to find existing channel by email or imap_login
    channel_email = Channel::Email.find_by(imap_login: user_email) ||
                    Channel::Email.find_by(email: user_email)

    if channel_email
      # Update existing channel
      Rails.logger.info("Microsoft: Updating existing channel for email=#{user_email}")
      channel_email.update!(
        imap_login: user_email,
        imap_address: 'outlook.office365.com',
        imap_port: '993',
        imap_enabled: true,
        provider: 'microsoft',
        provider_config: {
          access_token: parsed_body['access_token'],
          refresh_token: parsed_body['refresh_token'],
          expires_on: (Time.current.utc + parsed_body['expires_in'].seconds).to_s
        }
      )

      if channel_email.inbox
        channel_email.inbox.update!(name: users_data['displayName'] || fallback_name(user_email))
      end
    else
      # Create new channel and inbox
      Rails.logger.info("Microsoft: Creating new channel for email=#{user_email}")
      ActiveRecord::Base.transaction do
        channel_email = Channel::Email.create!(
          email: user_email,
          imap_login: user_email,
          imap_address: 'outlook.office365.com',
          imap_port: '993',
          imap_enabled: true,
          provider: 'microsoft',
          provider_config: {
            access_token: parsed_body['access_token'],
            refresh_token: parsed_body['refresh_token'],
            expires_on: (Time.current.utc + parsed_body['expires_in'].seconds).to_s
          }
        )

        Inbox.create!(
          channel: channel_email,
          name: users_data['displayName'] || fallback_name(user_email)
        )
      end
    end

    channel_email
  end

  def fallback_name(email)
    email.split('@').first.parameterize.titleize
  end
end
