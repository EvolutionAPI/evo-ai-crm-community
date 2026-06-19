# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public Chat Pages API', type: :request do
  let(:web_widget) { Channel::WebWidget.create!(website_url: 'https://chat.example.com') }
  let!(:inbox) { Inbox.create!(name: 'Chat Inbox', channel: web_widget) }

  let(:chat_page) do
    ChatPage.create!(
      title: 'Atendimento',
      website_token: web_widget.website_token,
      published: true,
      appearance: { 'primary_color' => '#1E40AF' }
    )
  end

  describe 'GET /public/api/v1/chat_pages/:slug' do
    it 'returns the published page config with the widget website_token' do
      get "/public/api/v1/chat_pages/#{chat_page.slug}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['data']['website_token']).to eq(web_widget.website_token)
      expect(body['data']['title']).to eq('Atendimento')
      expect(body['data']['appearance']['primary_color']).to eq('#1E40AF')
    end

    it '404s for a draft page without leaking it' do
      chat_page.update!(published: false)
      get "/public/api/v1/chat_pages/#{chat_page.slug}"
      expect(response).to have_http_status(:not_found)
    end

    it '404s for an unknown slug' do
      get '/public/api/v1/chat_pages/does-not-exist'
      expect(response).to have_http_status(:not_found)
    end
  end
end
