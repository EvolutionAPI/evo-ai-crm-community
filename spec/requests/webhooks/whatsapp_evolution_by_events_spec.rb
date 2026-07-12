# frozen_string_literal: true

require 'rails_helper'

# EVO-2089: com WEBHOOK_GLOBAL_WEBHOOK_BY_EVENTS=true, a Evolution posta cada
# evento em /webhooks/whatsapp/evolution/<evento> (ex.: messages-upsert). Antes
# só existia a rota base -> 404 em todos os eventos -> nenhuma mensagem entrava.
# A rota :sub_event roteia para o mesmo process_payload; o nome NAO pode ser
# :event porque, no Rails, path params sobrescrevem os do corpo (o `event` do
# payload, "messages.upsert", seria trocado pelo "messages-upsert" da URL).
RSpec.describe 'Webhooks::Whatsapp Evolution by-events routing', type: :request do
  let(:payload) do
    {
      event: 'messages.upsert',
      instance: 'evo-instance',
      data: {
        key: { remoteJid: '5511999999999@s.whatsapp.net', fromMe: false, id: 'ABC123' },
        message: { conversation: 'oi' }
      }
    }
  end

  before { allow(Webhooks::WhatsappEventsJob).to receive(:perform_later) }

  it 'aceita a sub-rota por evento (nao 404) e enfileira o job' do
    post '/webhooks/whatsapp/evolution/messages-upsert', params: payload, as: :json

    expect(response).to have_http_status(:ok)
    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
  end

  it 'preserva o event do corpo (o :sub_event da URL nao sobrescreve params[:event])' do
    post '/webhooks/whatsapp/evolution/messages-upsert', params: payload, as: :json

    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later) do |hash|
      h = hash.with_indifferent_access
      expect(h[:event]).to eq('messages.upsert')     # do corpo, intacto
      expect(h[:sub_event]).to eq('messages-upsert') # da URL, apenas informativo
    end
  end

  it 'mantem a rota base funcionando (regressao)' do
    post '/webhooks/whatsapp/evolution', params: payload, as: :json

    expect(response).to have_http_status(:ok)
    expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
  end
end
