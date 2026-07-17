# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::EvolutionGo::HealthMonitorsController, type: :controller do
  describe 'GET #index' do
    it 'responds with success' do
      allow(EvolutionGoHealthMonitor).to receive_message_chain(:enabled, :order, :map).and_return([])
      get :index
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['success']).to be true
    end
  end

  describe 'POST #test' do
    it 'queues a health check' do
      monitor = instance_double(EvolutionGoHealthMonitor, id: 'test-id')
      allow(EvolutionGoHealthMonitor).to receive(:find).with('test-id').and_return(monitor)
      allow(EvolutionGo::HealthMonitorJob).to receive(:perform_later)

      post :test, params: { id: 'test-id' }

      expect(response).to have_http_status(:accepted)
      expect(EvolutionGo::HealthMonitorJob).to have_received(:perform_later).with('test-id')
    end
  end
end
