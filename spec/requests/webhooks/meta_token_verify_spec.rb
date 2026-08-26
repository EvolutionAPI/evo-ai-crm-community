# frozen_string_literal: true

require 'rails_helper'

# Verificado contra o app rodando em RAILS_ENV=production, via HTTP real:
#
#   - `render json:` NAO embrulha o challenge em aspas (o renderer do Rails
#     entrega uma String intacta) — o corpo ja saia byte a byte correto. O que
#     saia errado era so o `Content-Type: application/json`, e a Meta espera
#     text/plain no handshake.
#   - A rota por numero (`/webhooks/whatsapp/:phone_number`) nem chegava ao
#     render: `log_phone_specific_token_check` interpolava locais inexistentes e
#     estourava NameError -> 500 com token certo E com token errado. Como
#     `Inbox#callback_webhook_url` entrega justamente essa URL quando
#     WP_VERIFY_TOKEN nao esta configurado (o default de uma instalacao nova),
#     era esse 500 que derrubava o cadastro do canal.
RSpec.describe 'Webhooks Meta token verification', type: :request do
  let(:challenge) { '1158201444' }

  def verify_request(path, token)
    get path, params: { 'hub.mode' => 'subscribe', 'hub.verify_token' => token, 'hub.challenge' => challenge }
  end

  shared_examples 'echoes the challenge as plain text' do
    it 'responde 200 com o challenge byte a byte e como text/plain' do
      verify_request(path, valid_token)

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(challenge)
      expect(response.media_type).to eq('text/plain')
    end
  end

  shared_examples 'rejects a wrong token' do
    it 'responde 401 (nao 500) e nao ecoa o challenge' do
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

    it 'loga a checagem do token sem estourar NameError' do
      allow(Rails.logger).to receive(:info).and_call_original

      verify_request(path, valid_token)

      expect(response).to have_http_status(:ok)
      expect(Rails.logger).to have_received(:info)
        .with(/Phone-specific WhatsApp webhook verify token check.*provided=\[PRESENT\], channel=\[PRESENT\]/m)
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

    it 'aceita tambem o token do login direto do Instagram' do
      verify_request(path, 'ig-direct-token')

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq(challenge)
    end
  end
end
