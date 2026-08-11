class Api::V1::Instagram::AuthorizationsController < Api::V1::BaseController
  require_permissions({
    index: 'instagram_authorizations.read',
    show: 'instagram_authorizations.read',
    create: 'instagram_authorizations.write',
    update: 'instagram_authorizations.write',
    destroy: 'instagram_authorizations.delete',
    callback: 'instagram_authorizations.write'
  })
  include InstagramConcern
  include Instagram::IntegrationHelper


  def create
    # https://developers.facebook.com/docs/instagram-platform/instagram-api-with-instagram-login/business-login#step-1--get-authorization
    redirect_url = instagram_client.auth_code.authorize_url(
      {
        redirect_uri: "#{base_url}/instagram/callback",
        scope: REQUIRED_SCOPES.join(','),
        enable_fb_login: '0',
        force_authentication: '1',
        response_type: 'code',
        state: generate_instagram_token('community')
      }
    )
    if redirect_url
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
      identifier = verify_instagram_token(state)
      unless identifier.present?
        render json: { success: false, error: 'Invalid or expired state token' }, status: :unauthorized
        return
      end

      # Exchange code for access token
      response = instagram_client.auth_code.get_token(
        code,
        redirect_uri: "#{base_url}/instagram/callback",
        grant_type: 'authorization_code'
      )

      # Exchange for long-lived token
      long_lived_token_response = exchange_for_long_lived_token(response.token)

      # Fetch user details
      user_details = fetch_instagram_user_details(long_lived_token_response['access_token'])

      # Find or create channel and inbox
      channel_instagram = find_or_create_channel(user_details, long_lived_token_response)

      # Mark as reauthorized
      channel_instagram.reauthorized!

      render json: {
        success: true,
        inbox_id: channel_instagram.inbox.id,
        channel_id: channel_instagram.id
      }
    rescue StandardError => e
      Rails.logger.error("Instagram callback error: #{e.message}")
      Rails.logger.error(e.backtrace.join("\n"))
      render json: { success: false, error: e.message }, status: :unprocessable_entity
    end
  end

  private

  def find_or_create_channel(user_details, token_response)
    instagram_id = extract_instagram_user_id(user_details)
    expires_at = Time.current + token_response['expires_in'].seconds

    # Try to find existing channel
    channel_instagram = Channel::Instagram.find_by(
      instagram_id: instagram_id
    )

    if channel_instagram
      # Update existing channel
      Rails.logger.info("Instagram: Updating existing channel for instagram_id=#{instagram_id}")
      channel_instagram.update!(
        access_token: token_response['access_token'],
        expires_at: expires_at
      )

      if channel_instagram.inbox
        channel_instagram.inbox.update!(name: user_details['username'])
      end
    else
      # Create new channel and inbox
      Rails.logger.info("Instagram: Creating new channel for instagram_id=#{instagram_id}")
      ActiveRecord::Base.transaction do
        channel_instagram = Channel::Instagram.create!(
          access_token: token_response['access_token'],
          instagram_id: instagram_id,
          expires_at: expires_at
        )

        Inbox.create!(
          channel: channel_instagram,
          name: user_details['username']
        )
      end
    end

    channel_instagram
  end

  def extract_instagram_user_id(user_details)
    (user_details['user_id'] || user_details['id']).to_s
  end

end
