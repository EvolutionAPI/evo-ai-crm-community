# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::EvoFlow::SegmentsController, type: :controller do
  let(:fake_client) { instance_double(EvoFlow::Client) }
  let(:definition) { { 'entryNode' => { 'id' => 'entry', 'type' => 'Everyone' }, 'nodes' => [] } }

  before do
    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(EvoFlow::Client).to receive(:new).and_return(fake_client)
    # EVO-1938: these existing specs cover the proxy behavior, not authorization —
    # authenticate as a service token so the new require_permissions gate bypasses.
    Current.service_authenticated = true
  end

  after { Current.reset }

  # EVO-1938: the segments endpoints proxy to evo-flow and previously had NO
  # permission gate, so revoking segments.* from the agent only hid the Settings UI
  # while the API stayed open. These assert the require_permissions gate now 403s a
  # user that lacks the segment permission (the default agent) and lets an admin in.
  describe 'permission gating (EVO-1938)' do
    let(:current_user) { double('User', id: 'user-1') }

    before do
      Current.service_authenticated = false
      Current.user = current_user
      Current.evo_permission_cache = {}
    end

    it 'returns 403 on #index when the user lacks segments.read (the default agent)' do
      Current.evo_permission_cache['user:user-1:segments.read'] = false
      expect(fake_client).not_to receive(:get)

      get :index

      expect(response).to have_http_status(:forbidden)
    end

    it 'returns 403 on #destroy when the user lacks segments.delete' do
      Current.evo_permission_cache['user:user-1:segments.delete'] = false
      expect(fake_client).not_to receive(:delete)

      delete :destroy, params: { id: 'seg-1' }

      expect(response).to have_http_status(:forbidden)
    end

    it 'allows #index when the user holds segments.read (an administrator)' do
      Current.evo_permission_cache['user:user-1:segments.read'] = true
      allow(fake_client).to receive(:get).and_return({ 'segments' => [] })

      get :index

      expect(response).to have_http_status(:ok)
    end
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

  describe 'DELETE #destroy' do
    it 'forwards a DELETE to evo-flow and returns 200 with the body pass-through' do
      allow(fake_client).to receive(:delete)
        .with('/segments/seg-1')
        .and_return({ 'id' => 'seg-1', 'deleted' => true })

      delete :destroy, params: { id: 'seg-1' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(fake_client).to have_received(:delete).with('/segments/seg-1')
      expect(response.parsed_body).to eq('id' => 'seg-1', 'deleted' => true)
    end

    it 'ignores account-related params (AC3 — account never read from the request)' do
      allow(fake_client).to receive(:delete).with('/segments/seg-1').and_return({})

      delete :destroy, params: { id: 'seg-1', account_id: 'acc-evil', account: 'x' }, as: :json

      # The forwarded path carries only the id; no account is appended.
      expect(fake_client).to have_received(:delete).with('/segments/seg-1')
    end

    it 'renders an empty (204/null) evo-flow body without error (AC6)' do
      allow(fake_client).to receive(:delete).with('/segments/seg-1').and_return(nil)

      delete :destroy, params: { id: 'seg-1' }, as: :json

      expect(response).to have_http_status(:ok)
      # `render json: nil` serialises to the literal "null"; the FE only needs
      # a successful resolve, so this is the expected harmless body.
      expect(response.body).to eq('null')
    end

    it 'passes an evo-flow 404 through verbatim under an errors key' do
      error_body = { 'message' => 'Segment not found' }
      response_double = instance_double(HTTParty::Response, parsed_response: error_body)
      allow(fake_client).to receive(:delete)
        .and_raise(EvoFlow::HTTPError.new('evo-flow API error', 404, response_double))

      delete :destroy, params: { id: 'missing' }, as: :json

      expect(response).to have_http_status(404)
      expect(response.parsed_body).to eq('errors' => error_body)
    end
  end

  describe 'POST #recompute' do
    it 'forwards an empty-body POST to evo-flow for the given id' do
      allow(fake_client).to receive(:post)
        .with('/segments/seg-1/recompute', {})
        .and_return({ 'segmentId' => 'seg-1', 'contactsAdded' => 3 })

      post :recompute, params: { id: 'seg-1' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(fake_client).to have_received(:post).with('/segments/seg-1/recompute', {})
      expect(response.parsed_body).to eq('segmentId' => 'seg-1', 'contactsAdded' => 3)
    end

    it 'ignores account-related params (AC3 — empty body forwarded, no account)' do
      allow(fake_client).to receive(:post)
        .with('/segments/seg-1/recompute', {})
        .and_return({})

      post :recompute, params: { id: 'seg-1', account_id: 'acc-evil', account: 'x' }, as: :json

      # Body is a hardcoded {}; no account/account_id is forwarded to evo-flow.
      expect(fake_client).to have_received(:post).with('/segments/seg-1/recompute', {})
    end

    it 'passes an evo-flow 422 through verbatim under an errors key' do
      error_body = { 'message' => 'recompute failed' }
      response_double = instance_double(HTTParty::Response, parsed_response: error_body)
      allow(fake_client).to receive(:post)
        .and_raise(EvoFlow::HTTPError.new('evo-flow API error', 422, response_double))

      post :recompute, params: { id: 'seg-1' }, as: :json

      expect(response).to have_http_status(422)
      expect(response.parsed_body).to eq('errors' => error_body)
    end
  end

  describe 'POST #recompute_all' do
    it 'forwards an empty-body POST to the collection recompute-all endpoint' do
      allow(fake_client).to receive(:post)
        .with('/segments/recompute-all', {})
        .and_return({ 'results' => [], 'totalProcessingTimeMs' => 12 })

      post :recompute_all, as: :json

      expect(response).to have_http_status(:ok)
      expect(fake_client).to have_received(:post).with('/segments/recompute-all', {})
      expect(response.parsed_body).to eq('results' => [], 'totalProcessingTimeMs' => 12)
    end

    it 'ignores account-related params (AC3 — empty body forwarded, no account)' do
      allow(fake_client).to receive(:post)
        .with('/segments/recompute-all', {})
        .and_return({ 'results' => [] })

      post :recompute_all, params: { account_id: 'acc-evil', account: 'x' }, as: :json

      expect(fake_client).to have_received(:post).with('/segments/recompute-all', {})
    end

    it 'passes an evo-flow 5xx through verbatim under an errors key' do
      error_body = { 'message' => 'upstream boom' }
      response_double = instance_double(HTTParty::Response, parsed_response: error_body)
      allow(fake_client).to receive(:post)
        .and_raise(EvoFlow::HTTPError.new('evo-flow API error', 502, response_double))

      post :recompute_all, as: :json

      expect(response).to have_http_status(502)
      expect(response.parsed_body).to eq('errors' => error_body)
    end
  end

  describe 'GET #contact_ids' do
    it 'forwards :limit/:offset pagination to evo-flow and returns the body' do
      allow(fake_client).to receive(:get)
        .with('/segments/seg-1/contact-ids', { 'limit' => '50', 'offset' => '100' })
        .and_return({ 'contactIds' => %w[c1 c2], 'total' => 2, 'limit' => 50, 'offset' => 100 })

      get :contact_ids, params: { id: 'seg-1', limit: '50', offset: '100' }

      expect(response).to have_http_status(:ok)
      expect(fake_client).to have_received(:get)
        .with('/segments/seg-1/contact-ids', { 'limit' => '50', 'offset' => '100' })
      expect(response.parsed_body).to eq(
        'contactIds' => %w[c1 c2], 'total' => 2, 'limit' => 50, 'offset' => 100
      )
    end

    it 'ignores account-related params (AC3 — account never read from the request)' do
      allow(fake_client).to receive(:get)
        .with('/segments/seg-1/contact-ids', {})
        .and_return({ 'contactIds' => [], 'total' => 0 })

      get :contact_ids, params: { id: 'seg-1', account_id: 'acc-evil', account: 'x' }

      expect(fake_client).to have_received(:get).with('/segments/seg-1/contact-ids', {})
    end

    it 'passes an evo-flow 404 through verbatim under an errors key' do
      error_body = { 'message' => 'Segment not found' }
      response_double = instance_double(HTTParty::Response, parsed_response: error_body)
      allow(fake_client).to receive(:get)
        .and_raise(EvoFlow::HTTPError.new('evo-flow API error', 404, response_double))

      get :contact_ids, params: { id: 'missing' }

      expect(response).to have_http_status(404)
      expect(response.parsed_body).to eq('errors' => error_body)
    end
  end
end
