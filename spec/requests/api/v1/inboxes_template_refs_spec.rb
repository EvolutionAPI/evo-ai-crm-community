# frozen_string_literal: true

require 'rails_helper'

# EVO-1760: the inbox greeting / out-of-office message can reference a global
# MessageTemplate (greeting_message_template_id / out_of_office_message_template_id).
# These columns exist since EVO-1235; this spec covers the FE-facing contract:
# they must be permitted on update and echoed back by the serializer.
RSpec.describe 'PATCH /api/v1/inboxes/:id template refs', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(channel: channel, name: 'API Inbox') }
  let(:template_id) { '11111111-1111-4111-8111-111111111111' }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  it 'permits, persists and serializes greeting/out-of-office template ids' do
    patch "/api/v1/inboxes/#{inbox.id}",
          params: {
            greeting_enabled: true,
            greeting_message_template_id: template_id,
            working_hours_enabled: true,
            out_of_office_message_template_id: template_id
          },
          headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(inbox.reload.greeting_message_template_id).to eq(template_id)
    expect(inbox.out_of_office_message_template_id).to eq(template_id)
    expect(json_response['data']['greeting_message_template_id']).to eq(template_id)
    expect(json_response['data']['out_of_office_message_template_id']).to eq(template_id)
  end

  it 'clears the refs when the FE sends the "null" sentinel' do
    inbox.update!(greeting_message_template_id: template_id, out_of_office_message_template_id: template_id)

    patch "/api/v1/inboxes/#{inbox.id}",
          params: { greeting_message_template_id: 'null', out_of_office_message_template_id: 'null' },
          headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(inbox.reload.greeting_message_template_id).to be_nil
    expect(inbox.out_of_office_message_template_id).to be_nil
  end
end
