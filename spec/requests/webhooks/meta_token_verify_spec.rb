# frozen_string_literal: true

require 'rails_helper'

# Measured against the app running in RAILS_ENV=production over real HTTP:
# `render json:` did not quote the challenge (Rails renders a String as-is), only
# the Content-Type was wrong. What actually broke channel setup was a NameError in
# log_phone_specific_token_check: a 500 on the per-number route, with a right token
# and with a wrong one, and that is the URL Inbox#callback_webhook_url hands out
# when WP_VERIFY_TOKEN is unset — the default of a fresh install.
RSpec.describe 'Webhooks Meta token verification', type: :request do
  let(:challenge) { '1158201444' }

  def verify_request(path, token)
    get path, params: { 'hub.mode' => 'subscribe', 'hub.verify_token' => token, 'hub.challenge' => challenge }
  end

  shared_examples 'echoes the challenge as plain text' do
    it 'answers 200 with the challenge byte for byte, as text/plain' do
      verify_request(path, valid_token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(challenge)
      expect(response.media_type).to eq('text/plain')
    end
  end

  shared_examples 'rejects a wrong token' do
    it 'answers 401 (not 500) and does not echo the challenge' do
      verify_request(path, 'wrong-token')

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(challenge)
    end
  end

  describe 'WhatsApp global webhook' do
    let(:path) { '/webhooks/whatsapp' }
    let(:valid_token) { 'wp-global-token' }

    before { allow(GlobalConfig).to receive(:get_value).with('WP_VERIFY_TOKEN').and_return(valid_token) }

    it_behaves_like 'echoes the challenge as plain text'
    it_behaves_like 'rejects a wrong token'

    it 'logs the token check through the shared helper' do
      allow(Rails.logger).to receive(:info).and_call_original

      verify_request(path, valid_token)

      expect(Rails.logger).to have_received(:info)
        .with(/Global WhatsApp webhook verify token check: provided=\[PRESENT\], global=\[PRESENT\]/)
    end
  end

  describe 'WhatsApp per-number webhook' do
    let(:phone_number) { '+551199999999' }
    let(:path) { "/webhooks/whatsapp/#{phone_number}" }
    let(:valid_token) { 'wp-channel-token' }

    before do
      channel = instance_double(Channel::Whatsapp, provider_config: { 'webhook_verify_token' => valid_token })
      allow(Channel::Whatsapp).to receive(:find_by).with(phone_number: phone_number).and_return(channel)
    end

    it_behaves_like 'echoes the challenge as plain text'
    it_behaves_like 'rejects a wrong token'

    it 'logs the token check without raising NameError' do
      allow(Rails.logger).to receive(:info).and_call_original

      verify_request(path, valid_token)

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).to have_received(:info)
        .with(/Phone-specific WhatsApp webhook verify token check.*provided=\[PRESENT\], channel=\[PRESENT\]/m)
    end
  end

  # The URL a fresh install hands out points at a number that has no channel yet,
  # so this is the request the Meta panel actually makes first.
  describe 'WhatsApp per-number webhook with no channel for the number' do
    let(:path) { '/webhooks/whatsapp/+551188888888' }

    before { allow(Channel::Whatsapp).to receive(:find_by).and_return(nil) }

    it 'answers 401 instead of 500' do
      verify_request(path, 'any-token')

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(challenge)
    end
  end

  # provider_config is jsonb with a default, not NOT NULL, so a row can hold NULL.
  describe 'WhatsApp per-number webhook with a NULL provider_config' do
    let(:phone_number) { '+551177777777' }
    let(:path) { "/webhooks/whatsapp/#{phone_number}" }

    before do
      channel = instance_double(Channel::Whatsapp, provider_config: nil)
      allow(Channel::Whatsapp).to receive(:find_by).with(phone_number: phone_number).and_return(channel)
    end

    it 'answers 401 instead of 500' do
      verify_request(path, 'any-token')

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(challenge)
    end
  end

  describe 'Instagram webhook' do
    let(:path) { '/webhooks/instagram' }
    let(:valid_token) { 'ig-token' }

    before do
      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load).with('IG_VERIFY_TOKEN', '').and_return(valid_token)
      allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_VERIFY_TOKEN', '').and_return('ig-direct-token')
    end

    it_behaves_like 'echoes the challenge as plain text'
    it_behaves_like 'rejects a wrong token'

    it 'also accepts the direct Instagram login token' do
      verify_request(path, 'ig-direct-token')

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(challenge)
    end
  end

  describe 'Instagram webhook with no token configured' do
    before do
      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load).with('IG_VERIFY_TOKEN', '').and_return('')
      allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_VERIFY_TOKEN', '').and_return('')
    end

    it 'refuses a blank hub.verify_token instead of matching the blank default' do
      verify_request('/webhooks/instagram', '')

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(challenge)
    end
  end

  # The Facebook channel never went through MetaTokenVerifyConcern: the handshake is
  # answered by the facebook-messenger gem mounted at /bot, which delegates to
  # EvolutionFbProvider. The gem never sets a status, so a refusal is a 200 whose body
  # is the error string — asserting that exact body is what proves it refused.
  describe 'Facebook webhook (facebook-messenger gem at /bot)' do
    let(:path) { '/bot' }

    context 'with FB_VERIFY_TOKEN configured' do
      before do
        allow(GlobalConfigService).to receive(:load).and_call_original
        allow(GlobalConfigService).to receive(:load).with('FB_VERIFY_TOKEN', '').and_return('fb-token')
      end

      it 'echoes the challenge for the right token' do
        verify_request(path, 'fb-token')

        expect(response).to have_http_status(:ok)
        expect(response.body).to eq(challenge)
      end

      it 'refuses a wrong token' do
        verify_request(path, 'wrong-token')

        expect(response.body).to eq('Error; wrong verify token')
      end
    end

    context 'without FB_VERIFY_TOKEN configured' do
      before do
        allow(GlobalConfigService).to receive(:load).and_call_original
        allow(GlobalConfigService).to receive(:load).with('FB_VERIFY_TOKEN', '').and_return('')
      end

      it 'refuses any token instead of verifying every one of them' do
        verify_request(path, 'anything')

        expect(response.body).to eq('Error; wrong verify token')
      end
    end
  end
end
