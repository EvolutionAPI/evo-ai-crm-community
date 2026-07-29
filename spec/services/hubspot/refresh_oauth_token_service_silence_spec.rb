# frozen_string_literal: true

require 'rails_helper'

# EVO-2250, collateral of the credential survey.
#
# The refresh returns the STALE token when renewal fails. That fallback is
# deliberate and stays: the caller contract is "give me a token", and failing
# hard there would break every consumer mid-conversation. What was wrong is that
# the failure was invisible — an integration could be dead for days with nothing
# but a debug-level line to show for it.
RSpec.describe Hubspot::RefreshOauthTokenService do
  let(:hook) do
    Integrations::Hook.create!(
      app_id: 'hubspot',
      status: 'enabled',
      access_token: 'token-velho',
      settings: { 'refresh_token' => 'r-1', 'expires_at' => 1.hour.ago.to_s }
    )
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_return('valor')
  end

  describe 'when the renewal fails' do
    before do
      allow(HTTParty).to receive(:post).and_raise(Errno::ECONNREFUSED)
    end

    it 'still returns the stale token, keeping the caller contract' do
      expect(described_class.new(hook: hook).access_token).to eq('token-velho')
    end

    # The silence is what dies: an operator has to be able to see this in the
    # logs at the level failures are actually read at.
    it 'logs the failure as an error, not as debug noise' do
      expect(Rails.logger).to receive(:error).with(/hubspot/i).at_least(:once)

      described_class.new(hook: hook).access_token
    end

    # Reauthorizable is the mechanism this codebase already has for "tell the
    # human": it counts failures in Redis and, past the threshold, e-mails and
    # deactivates. Bypassing it is what made the failure silent.
    it 'counts the failure through Reauthorizable so the existing escalation fires' do
      expect(hook).to receive(:authorization_error!).at_least(:once)

      described_class.new(hook: hook).access_token
    end
  end

  describe 'when the renewal succeeds' do
    before do
      response = instance_double(HTTParty::Response, success?: true,
                                                     body: { access_token: 'token-novo', refresh_token: 'r-2',
                                                             expires_in: 3600 }.to_json)
      allow(HTTParty).to receive(:post).and_return(response)
    end

    it 'returns the fresh token and never reports an auth error' do
      expect(hook).not_to receive(:authorization_error!)

      expect(described_class.new(hook: hook).access_token).to eq('token-novo')
    end
  end

  describe 'when there is no refresh token' do
    let(:hook) do
      Integrations::Hook.create!(app_id: 'hubspot', status: 'enabled', access_token: 'token-velho',
                                 settings: { 'expires_at' => 1.hour.ago.to_s })
    end

    it 'returns the stored token without pretending a refresh happened' do
      expect(HTTParty).not_to receive(:post)

      expect(described_class.new(hook: hook).access_token).to eq('token-velho')
    end
  end
end
