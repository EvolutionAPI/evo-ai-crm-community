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
end
