# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::EvoFlow::SegmentsController, type: :controller do
  let(:fake_client) { instance_double(EvoFlow::Client) }
  let(:definition) { { 'entryNode' => { 'id' => 'entry', 'type' => 'Everyone' }, 'nodes' => [] } }

  before do
    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(EvoFlow::Client).to receive(:new).and_return(fake_client)
  end

  describe 'POST #create' do
    it 'forwards to evo-flow and returns 201 with the body pass-through' do
      allow(fake_client).to receive(:post)
        .with('/segments', { name: 'VIPs', definition: definition })
        .and_return({ 'id' => 'seg-1', 'name' => 'VIPs' })

      post :create, params: { name: 'VIPs', definition: definition }, as: :json

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq('id' => 'seg-1', 'name' => 'VIPs')
    end

    it 'passes an evo-flow 422 through verbatim under an errors key' do
      error_body = { 'message' => 'invalid', 'details' => ['bad event'] }
      response_double = instance_double(HTTParty::Response, parsed_response: error_body)
      allow(fake_client).to receive(:post)
        .and_raise(EvoFlow::HTTPError.new('evo-flow API error', 422, response_double))

      post :create, params: { name: 'X', definition: definition }, as: :json

      expect(response).to have_http_status(422)
      expect(response.parsed_body).to eq('errors' => error_body)
    end
  end

  describe 'POST #preview' do
    it 'forwards the inline definition and returns the preview body' do
      allow(fake_client).to receive(:post)
        .with('/segments/preview', { definition: definition })
        .and_return({ 'count' => 7, 'sample' => [{ 'id' => 'c1' }] })

      post :preview, params: { definition: definition }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('count' => 7, 'sample' => [{ 'id' => 'c1' }])
    end

    it 'rejects a missing definition before hitting the client (422)' do
      expect(fake_client).not_to receive(:post)

      post :preview, params: {}

      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'rejects an over-nested definition with 413 before hitting the client' do
      expect(fake_client).not_to receive(:post)

      deep = { 'v' => 1 }
      40.times { deep = { 'n' => deep } }

      post :preview, params: { definition: deep }, as: :json

      expect(response).to have_http_status(:payload_too_large)
    end
  end

  describe 'GET #index' do
    it 'forwards pagination params through to evo-flow' do
      allow(fake_client).to receive(:get)
        .with('/segments', { 'page' => '2', 'limit' => '25' })
        .and_return({ 'segments' => [], 'total' => 0, 'page' => 2, 'limit' => 25 })

      get :index, params: { page: '2', limit: '25' }

      expect(response).to have_http_status(:ok)
      expect(fake_client).to have_received(:get).with('/segments', { 'page' => '2', 'limit' => '25' })
    end
  end

  describe 'PUT #update' do
    it 'issues a PUT to evo-flow for the given id' do
      allow(fake_client).to receive(:put)
        .with('/segments/seg-9', { name: 'Renamed', definition: definition })
        .and_return({ 'id' => 'seg-9', 'name' => 'Renamed' })

      put :update, params: { id: 'seg-9', name: 'Renamed', definition: definition }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('id' => 'seg-9', 'name' => 'Renamed')
    end
  end
end
