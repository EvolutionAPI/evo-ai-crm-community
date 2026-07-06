# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Channel OAuth callbacks' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

# EVO-2014: with the backend API-only (EVOLUTION_API_ONLY_SERVER default true),
# the in-app app_*_inbox route helpers are not registered. Channel OAuth callbacks
# used them and raised NoMethodError (HTTP 500). They must instead redirect to the
# frontend host — which also requires allow_other_host under load_defaults 7.0.
RSpec.describe 'Channel OAuth callbacks redirect to the frontend (EVO-2014)', type: :request do
  frontend = 'https://app.example.test'

  around do |example|
    previous = ENV.fetch('FRONTEND_URL', nil)
    ENV['FRONTEND_URL'] = frontend
    example.run
  ensure
    previous.nil? ? ENV.delete('FRONTEND_URL') : ENV['FRONTEND_URL'] = previous
  end

  it 'whatsapp callback error path redirects to the frontend instead of 500' do
    get '/whatsapp/callback', params: { error: 'access_denied', error_description: 'user cancelled' }

    expect(response).to have_http_status(:found)
    expect(response.location).to start_with("#{frontend}/app/settings/inboxes/new/whatsapp")
    expect(response.location).to include('error_type=access_denied')
  end

  it 'instagram callback error path redirects to the frontend instead of 500' do
    get '/instagram/callback', params: { error: 'access_denied', error_description: 'user cancelled' }

    expect(response).to have_http_status(:found)
    expect(response.location).to start_with("#{frontend}/app/settings/inboxes/new/instagram")
    expect(response.location).to include('error_type=access_denied')
  end

  it 'twitter callback denied path redirects to the frontend instead of 500' do
    get '/twitter/callback', params: { denied: '1' }

    expect(response).to have_http_status(:found)
    expect(response.location).to eq("#{frontend}/app/settings/inboxes/new/twitter")
  end

  # The happy path is the primary behavior this fix ships: a *successful* channel
  # connect must land on the frontend inbox routes, not 500 on a missing app_* helper.
  # Twitter and the email (microsoft/google) callbacks reuse the exact same two
  # literals asserted here (".../new/:id/agents" for new, ".../:id" for existing),
  # so covering whatsapp + instagram guards every distinct success target string.
  describe 'success paths' do
    it 'whatsapp success redirects to the frontend setup page carrying code and state' do
      get '/whatsapp/callback', params: { code: 'auth-code', state: 'st-123' }

      expect(response).to have_http_status(:found)
      expect(response.location).to start_with("#{frontend}/app/settings/inboxes/new/whatsapp")
      expect(response.location).to include('code=auth-code')
      expect(response.location).to include('state=st-123')
    end

    it 'drops blank query params and never double-slashes a trailing-slash FRONTEND_URL' do
      ENV['FRONTEND_URL'] = "#{frontend}/"

      get '/whatsapp/callback', params: { code: 'auth-code' }

      expect(response.location).to start_with("#{frontend}/app/settings/inboxes/new/whatsapp")
      expect(response.location).not_to include("#{frontend}//app")
      expect(response.location).not_to include('state=')
    end

    it 'instagram success on a brand-new inbox lands on the agents step' do
      stub_instagram_token_exchange(inbox_id: 7, already_exists: false)

      get '/instagram/callback', params: { code: 'oauth-code' }

      expect(response).to have_http_status(:found)
      expect(response.location).to eq("#{frontend}/app/settings/inboxes/new/7/agents")
    end

    it 'instagram success on an existing inbox lands on its settings page' do
      stub_instagram_token_exchange(inbox_id: 42, already_exists: true)

      get '/instagram/callback', params: { code: 'oauth-code' }

      expect(response).to have_http_status(:found)
      expect(response.location).to eq("#{frontend}/app/settings/inboxes/42")
    end
  end

  # Stub the OAuth token exchange + inbox resolution seams so the example exercises
  # only the redirect target this fix changed, not Instagram's token/DB machinery.
  # The OAuth2 client is an opaque external object (no loadable class to verify
  # against), and a request spec has no handle on the controller instance, so plain
  # doubles + any_instance are the pragmatic seam here.
  def stub_instagram_token_exchange(inbox_id:, already_exists:)
    client = double(auth_code: double(get_token: double(token: 'short-token'))) # rubocop:disable RSpec/VerifiedDoubles
    # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Instagram::CallbacksController).to receive(:instagram_client).and_return(client)
    allow_any_instance_of(Instagram::CallbacksController)
      .to receive(:exchange_for_long_lived_token).and_return('access_token' => 'long-token')
    allow_any_instance_of(Instagram::CallbacksController)
      .to receive(:find_or_create_inbox).and_return([instance_double(Inbox, id: inbox_id), already_exists])
    # rubocop:enable RSpec/AnyInstance
  end
end
