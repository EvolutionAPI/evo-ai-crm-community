class Api::V1::Google::AuthorizationsController < Api::V1::BaseController
  require_permissions({
    index: 'google_authorizations.read',
    show: 'google_authorizations.read',
    create: 'google_authorizations.write',
    update: 'google_authorizations.write',
    destroy: 'google_authorizations.delete',
    callback: 'google_authorizations.write'
  })
  include GoogleConcern


  def create
    email = params[:authorization][:email]
    state_token = generate_google_token('community')
    callback_url = "#{base_url}/google/callback"

    Rails.logger.info "[GOOGLE_AUTH] Creating authorization for email=#{email}, callback_url=#{callback_url}"

    redirect_url = google_client.auth_code.authorize_url(
      {
        redirect_uri: callback_url,
        scope: 'email profile https://mail.google.com/',
        response_type: 'code',
        prompt: 'consent', # the oauth flow does not return a refresh token, this is supposed to fix it
        access_type: 'offline', # the default is 'online'
        client_id: GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil),
        state: state_token
      }
    )

    if redirect_url
      cache_key = "google::#{email.downcase}"
      ::Redis::Alfred.setex(cache_key, 'community', 5.minutes)
      Rails.logger.info "[GOOGLE_AUTH] Authorization URL generated successfully. Cache key: #{cache_key}"
      render json: { success: true, url: redirect_url }
    else
      Rails.logger.error "[GOOGLE_AUTH] Failed to generate authorization URL"
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
      identifier = verify_google_token(state)

      unless identifier
        render json: { success: false, error: 'Invalid or expired state token' }, status: :unauthorized
        return
      end

      # Exchange code for access token
      response = google_client.auth_code.get_token(
        code,
        redirect_uri: "#{base_url}/google/callback"
      )

      # Get user email from JWT id_token
      parsed_body = response.response.parsed
      decoded_token = JWT.decode parsed_body['id_token'], nil, false
      users_data = decoded_token[0]
      user_email = users_data['email']

      channel_email = find_or_create_channel(user_email, users_data, parsed_body)

      # Mark as reauthorized
      channel_email.reauthorized!

      # Enable push notifications automatically for Gmail
      if channel_email.google?
        begin
          Rails.logger.info "[GMAIL_PUSH] Attempting to enable push for #{channel_email.email}"
          channel_email.enable_push!
          Rails.logger.info "[GMAIL_PUSH] Push enabled successfully for #{channel_email.email}"
        rescue StandardError => e
          Rails.logger.error "[GMAIL_PUSH] Failed to enable push for #{channel_email.email}: #{e.message}"
          Rails.logger.error "[GMAIL_PUSH] Backtrace: #{e.backtrace.first(5).join("\n")}"
          EvolutionExceptionTracker.new(e, account: nil).capture_exception
        end
      end

      # Clean up cache (if exists)
      cache_key = "google::#{user_email.downcase}"
      ::Redis::Alfred.delete(cache_key)

      render json: {
        success: true,
        inbox_id: channel_email.inbox.id,
        channel_id: channel_email.id,
        email: user_email
      }
    rescue StandardError => e
      Rails.logger.error("Google callback error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def find_or_create_channel(user_email, users_data, parsed_body)
    # Try to find existing channel by email
    channel_email = Channel::Email.find_by(email: user_email)

    if channel_email
      # Update existing channel
      Rails.logger.info("Google: Updating existing channel for email=#{user_email}")
      # Merge provider_config to preserve existing settings like push_enabled and watch_history_id
      existing_config = channel_email.provider_config || {}
      merged_config = existing_config.merge(
        'access_token' => parsed_body['access_token'],
        'refresh_token' => parsed_body['refresh_token'],
        'expires_on' => (Time.current.utc + 1.hour).to_s
      )
      channel_email.update!(
        provider: 'google',
        provider_config: merged_config
      )

      if channel_email.inbox
        channel_email.inbox.update!(name: users_data['name'] || fallback_name(user_email))
      end
    else
      # Create new channel and inbox
      Rails.logger.info("Google: Creating new channel for email=#{user_email}")
      ActiveRecord::Base.transaction do
        channel_email = Channel::Email.create!(
          email: user_email,
          provider: 'google',
          provider_config: {
            access_token: parsed_body['access_token'],
            refresh_token: parsed_body['refresh_token'],
            expires_on: (Time.current.utc + 1.hour).to_s
          }
        )

        Inbox.create!(
          channel: channel_email,
          name: users_data['name'] || fallback_name(user_email)
        )
      end
    end

    channel_email
  end

  def fallback_name(email)
    email.split('@').first.parameterize.titleize
  end

end
