# frozen_string_literal: true

require 'rails_helper'

# EVO-1255: evo-flow journey nodes list an inbox's templates server-side with
# the service token. The per-inbox path runs InboxPolicy#message_templates?
# (unlike ?global=true, which skips authorize), so the policy must honor
# service authentication instead of dereferencing a nil user.
RSpec.describe 'Api::V1::Inboxes message templates (service token, per-inbox)', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }
  let(:channel) { Channel::Api.create!(hmac_mandatory: false) }
  let(:inbox) { Inbox.create!(channel: channel, name: "Inbox #{SecureRandom.hex(3)}") }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  it 'lists the inbox templates with a valid service token' do
    template = MessageTemplate.create!(
      name: "ch-#{SecureRandom.hex(4)}",
      content: 'Olá {{first_name}}',
      channel: channel
    )

    get "/api/v1/inboxes/#{inbox.id}/message_templates?active=true&per_page=-1",
        headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    names = response.parsed_body['data'].map { |t| t['name'] }
    expect(names).to include(template.name)
  end

  it 'rejects the call without a service token or user' do
    get "/api/v1/inboxes/#{inbox.id}/message_templates", as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
