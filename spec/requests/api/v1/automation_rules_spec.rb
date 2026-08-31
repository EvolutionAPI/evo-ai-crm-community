# frozen_string_literal: true

require 'rails_helper'

# Request coverage for the automation rules permit (CRM-298).
#
# `conditions[].values` is shape-polymorphic: an array of scalars for regular
# operators, but an object `{to: [], from: []}` for `attribute_changed` — the
# exact shape ConditionsFilterService reads back. A flat `permit` declaration
# cannot express "array OR hash", so the controller builds the conditions
# permit by hand. These specs pin both shapes surviving create/update, unknown
# keys being dropped, and an API-created attribute_changed rule actually
# firing through the listener chain.

AutomationRuleRequestEvent = Struct.new(:data) unless defined?(AutomationRuleRequestEvent)

RSpec.describe 'Api::V1::AutomationRules', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }
  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  let!(:label) { Label.create!(title: 'vip', color: '#abcdef') }

  def json_response
    JSON.parse(response.body)
  end

  def rule_payload(conditions:)
    {
      name: "regra-#{SecureRandom.hex(4)}",
      event_name: 'conversation_updated',
      active: true,
      mode: 'simple',
      conditions: conditions,
      actions: [{ action_name: 'change_priority', action_params: ['urgent'] }]
    }
  end

  def persisted_rule
    AutomationRule.find(json_response.dig('data', 'id'))
  end

  describe 'POST /api/v1/automation_rules' do
    it 'persists object-shaped values ({to, from}) for attribute_changed alongside array-shaped values' do
      payload = rule_payload(
        conditions: [
          { attribute_key: 'labels', filter_operator: 'attribute_changed', query_operator: 'AND',
            values: { to: [label.id], from: [] } },
          { attribute_key: 'status', filter_operator: 'equal_to', query_operator: '',
            values: ['open'] }
        ]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      conditions = persisted_rule.conditions
      expect(conditions[0]['values']).to eq({ 'to' => [label.id], 'from' => [] })
      expect(conditions[1]['values']).to eq(['open'])
    end

    it 'drops unknown keys from conditions and from object-shaped values' do
      payload = rule_payload(
        conditions: [
          { attribute_key: 'labels', filter_operator: 'attribute_changed', query_operator: '',
            forged: 'nope', values: { to: [label.id], evil: ['x'] } }
        ]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      condition = persisted_rule.conditions.first
      expect(condition).not_to have_key('forged')
      expect(condition['values']).to eq({ 'to' => [label.id] })
    end

    it 'persists a valueless condition (is_present) without a values key and without error' do
      payload = rule_payload(
        conditions: [
          { attribute_key: 'assignee_id', filter_operator: 'is_present', query_operator: '' }
        ]
      )

      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:created)
      expect(persisted_rule.conditions.first).not_to have_key('values')
    end
  end

  describe 'PATCH /api/v1/automation_rules/:id' do
    let!(:rule) do
      AutomationRule.create!(
        name: 'regra-update', event_name: 'conversation_updated', active: true, mode: 'simple',
        conditions: [{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to',
                       'query_operator' => '', 'values' => ['open'] }],
        actions: [{ 'action_name' => 'change_priority', 'action_params' => ['urgent'] }]
      )
    end

    it 'persists both values shapes on update' do
      payload = {
        conditions: [
          { attribute_key: 'labels', filter_operator: 'attribute_changed', query_operator: 'AND',
            values: { to: [label.id], from: [] } },
          { attribute_key: 'status', filter_operator: 'equal_to', query_operator: '',
            values: ['resolved'] }
        ]
      }

      patch "/api/v1/automation_rules/#{rule.id}", params: payload, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      conditions = rule.reload.conditions
      expect(conditions[0]['values']).to eq({ 'to' => [label.id], 'from' => [] })
      expect(conditions[1]['values']).to eq(['resolved'])
    end
  end

  describe 'an API-created attribute_changed rule fires' do
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
    let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    it 'triggers the action service when the watched label is added' do
      payload = rule_payload(
        conditions: [
          { attribute_key: 'labels', filter_operator: 'attribute_changed', query_operator: '',
            values: { to: [label.id], from: [] } }
        ]
      )
      post '/api/v1/automation_rules', params: payload, headers: headers, as: :json
      expect(response).to have_http_status(:created)
      rule = persisted_rule

      event = AutomationRuleRequestEvent.new({
                                               conversation: conversation,
                                               changed_attributes: { 'label_list' => [[], ['vip']] }
                                             })
      service_double = instance_double(AutomationRules::ActionService, perform: nil)
      expect(AutomationRules::ActionService).to receive(:new)
        .with(rule, nil, conversation, hash_including(:recorder)).once.and_return(service_double)
      expect(service_double).to receive(:perform).once

      AutomationRuleListener.instance.conversation_updated(event)
    end
  end
end
