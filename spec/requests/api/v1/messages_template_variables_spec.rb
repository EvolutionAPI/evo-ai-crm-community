# frozen_string_literal: true

require 'rails_helper'

# EVO-1267: the evo-flow journey runtime sends template variables as
# {{root.path}} strings (plus per-variable fallbacks) and the CRM resolves
# them against the conversation at render time via TemplateVariableResolver.
RSpec.describe 'POST /api/v1/conversations/:id/messages (template variables)', type: :request do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://tpl.example.com') }
  let(:inbox) { Inbox.create!(name: 'Spec Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'João', email: 'joao@example.com') }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  let!(:template) do
    MessageTemplate.create!(
      name: "welcome-#{SecureRandom.hex(4)}",
      content: 'Olá {{first_name}}, código {{code}}, deal {{deal}}',
      language: 'pt_BR',
      channel: channel,
      variables: [{ 'name' => 'first_name', 'required' => true }, { 'name' => 'code' }, { 'name' => 'deal' }]
    )
  end

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def post_message(template_params, content: 'node fallback body')
    post "/api/v1/conversations/#{conversation.id}/messages",
         params: { content: content, template_params: template_params },
         headers: headers,
         as: :json
  end

  it 'resolves {{root.path}} values and applies fallbacks before rendering' do
    post_message(
      {
        name: template.name,
        language: 'pt_BR',
        processed_params: { first_name: '{{contact.name}}', code: 'ABC', deal: '{{contact.deal_value}}' },
        variable_fallbacks: { deal: 'sem valor' }
      }
    )

    expect(response).to have_http_status(:created)
    message = conversation.messages.last
    expect(message.content).to eq('Olá João, código ABC, deal sem valor')
  end

  it 'keeps the caller-rendered content when a required variable resolves blank without fallback' do
    post_message(
      {
        name: template.name,
        language: 'pt_BR',
        processed_params: { first_name: '{{contact.undefined_field}}', code: 'ABC', deal: 'x' }
      }
    )

    expect(response).to have_http_status(:created)
    expect(conversation.messages.last.content).to eq('node fallback body')
  end

  it 'does not re-expand pre-resolved envelopes (variables_resolved flag)' do
    # Final content still passes through the Liquidable before_create hook, so
    # the assertable seam is the resolver itself staying un-invoked.
    expect(TemplateVariableResolver).not_to receive(:new)

    post_message(
      {
        name: template.name,
        language: 'pt_BR',
        processed_params: { first_name: '{{contact.name}}', code: 'C', deal: 'd' },
        variables_resolved: true
      }
    )

    expect(response).to have_http_status(:created)
  end
end
