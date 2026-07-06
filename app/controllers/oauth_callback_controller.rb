class OauthCallbackController < ApplicationController
  include FrontendRedirectable

  # Load EvolutionExceptionTracker (using load to avoid Zeitwerk constant name mismatch)
  load Rails.root.join('lib', 'evolution_exception_tracker.rb').to_s unless defined?(EvolutionExceptionTracker)

  def show
    @response = oauth_client.auth_code.get_token(
      oauth_code,
      redirect_uri: "#{base_url}/#{provider_name}/callback"
    )

    handle_response
    ::Redis::Alfred.delete(cache_key)
  rescue StandardError => e
    EvolutionExceptionTracker.new(e).capture_exception
    redirect_to '/'
  end

  private

  def handle_response
    inbox, already_exists = find_or_create_inbox

    if already_exists
      redirect_to_frontend("/app/settings/inboxes/#{inbox.id}")
    else
      redirect_to_frontend("/app/settings/inboxes/new/#{inbox.id}/agents")
    end
  end

  def find_or_create_inbox
    channel_email = find_channel_by_email
    # we need this value to know where to redirect on sucessful processing of the callback
    channel_exists = channel_email.present?

    channel_email ||= create_channel_with_inbox
    update_channel(channel_email)

    # Call provider-specific after_update hook if defined
    after_channel_update(channel_email) if respond_to?(:after_channel_update, true)

    # reauthorize channel, this code path only triggers when microsoft auth is successful
    # reauthorized will also update cache keys for the associated inbox
    channel_email.reauthorized!

    [channel_email.inbox, channel_exists]
  end

  def find_channel_by_email
    Channel::Email.find_by(email: users_data['email'])
  end

  def update_channel(channel_email)
    # Merge provider_config to preserve existing settings like push_enabled and watch_history_id
    existing_config = channel_email.provider_config || {}
    merged_config = existing_config.merge(
      'access_token' => parsed_body['access_token'],
      'refresh_token' => parsed_body['refresh_token'],
      'expires_on' => (Time.current.utc + 1.hour).to_s
    )
    channel_email.update!({
                            imap_login: users_data['email'], imap_address: imap_address,
                            imap_port: '993', imap_enabled: true,
                            provider: provider_name,
                            provider_config: merged_config
                          })
  end

  def provider_name
    raise NotImplementedError
  end

  def oauth_client
    raise NotImplementedError
  end

  def cache_key
    "#{provider_name}::#{users_data['email'].downcase}"
  end

  def create_channel_with_inbox
    ActiveRecord::Base.transaction do
      channel_email = Channel::Email.create!(email: users_data['email'])

      Inbox.create!(
        channel: channel_email,
        name: users_data['name'] || fallback_name
      )
      channel_email
    end
  end

  def users_data
    decoded_token = JWT.decode parsed_body[:id_token], nil, false
    decoded_token[0]
  end

  # Fallback name, for when name field is missing from users_data
  def fallback_name
    users_data['email'].split('@').first.parameterize.titleize
  end

  def oauth_code
    params[:code]
  end

  def base_url
    ENV.fetch('FRONTEND_URL', 'http://localhost:3000')
  end

  def parsed_body
    @parsed_body ||= @response.response.parsed
  end
end
