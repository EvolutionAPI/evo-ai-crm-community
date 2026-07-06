class Twitter::CallbacksController < Twitter::BaseController
  include TwitterConcern
  include FrontendRedirectable

  def show
    return redirect_to twitter_app_redirect_url, allow_other_host: true if permitted_params[:denied]

    @response = ensure_access_token
    return redirect_to twitter_app_redirect_url, allow_other_host: true if @response.status != '200'

    ActiveRecord::Base.transaction do
      inbox = create_inbox
      ::Redis::Alfred.delete(permitted_params[:oauth_token])
      ::Twitter::WebhookSubscribeService.new(inbox_id: inbox.id).perform
      redirect_to_frontend("/app/settings/inboxes/new/#{inbox.id}/agents")
    end
  rescue StandardError => e
    EvolutionExceptionTracker.new(e).capture_exception
    redirect_to twitter_app_redirect_url, allow_other_host: true
  end

  private

  def parsed_body
    @parsed_body ||= Rack::Utils.parse_nested_query(@response.raw_response.body)
  end

  def twitter_app_redirect_url
    frontend_app_url('/app/settings/inboxes/new/twitter')
  end

  def ensure_access_token
    twitter_client.access_token(
      oauth_token: permitted_params[:oauth_token],
      oauth_verifier: permitted_params[:oauth_verifier]
    )
  end

  def create_inbox
    twitter_profile = Channel::TwitterProfile.create!(
      twitter_access_token: parsed_body['oauth_token'],
      twitter_access_token_secret: parsed_body['oauth_token_secret'],
      profile_id: parsed_body['user_id']
    )
    inbox = Inbox.create!(
      name: parsed_body['screen_name'],
      channel: twitter_profile
    )
    save_profile_image(inbox)
    inbox
  end

  def save_profile_image(inbox)
    response = twitter_client.user_show(screen_name: inbox.name)

    return unless response.status.to_i == 200

    parsed_user_profile = response.body

    ::Avatar::AvatarFromUrlJob.perform_later(inbox, parsed_user_profile['profile_image_url_https'])
  end

  def permitted_params
    params.permit(:oauth_token, :oauth_verifier, :denied)
  end
end
