# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'API-only routing default' do
    it 'has routing spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

# EVO-2010: the backend is API-only (vite_rails removed, no dashboard views), so
# EVOLUTION_API_ONLY_SERVER must default to true. With the old default (false)
# root routed to dashboard#index, which tried to render the missing 'vueapp'
# layout and answered HTTP 406.
RSpec.describe 'API-only routing default (EVO-2010)', type: :routing do
  it 'routes root to api#index when EVOLUTION_API_ONLY_SERVER is unset' do
    expect(get: '/').to route_to('api#index')
  end

  it 'does not draw the legacy frontend routes by default' do
    expect(get: '/app').not_to be_routable
  end

  it 'does not draw the removed installation onboarding endpoints (EVO-2014)' do
    expect(get: '/installation/onboarding').not_to be_routable
    expect(post: '/installation/onboarding').not_to be_routable
  end

  # EVO-2014: slack_uploads was nested under the legacy (non-API-only) branch, so
  # Slack's avatar/attachment fetches 404'd. It is consumed by Slack, not the SPA,
  # and must stay registered when the backend is API-only.
  it 'keeps the slack_uploads route registered when API-only (EVO-2014)' do
    expect(get: '/slack_uploads').to route_to('slack_uploads#show')
  end

  context 'with EVOLUTION_API_ONLY_SERVER=false (legacy backend-served SPA)' do
    around do |example|
      ENV['EVOLUTION_API_ONLY_SERVER'] = 'false'
      Rails.application.reload_routes!
      example.run
    ensure
      ENV.delete('EVOLUTION_API_ONLY_SERVER')
      Rails.application.reload_routes!
    end

    it 'keeps the legacy frontend routes registered' do
      expect(get: '/').to route_to('dashboard#index')
      expect(get: '/app').to route_to('dashboard#index')
    end
  end
end
