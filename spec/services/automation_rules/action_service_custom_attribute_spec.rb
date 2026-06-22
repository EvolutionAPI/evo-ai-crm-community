# frozen_string_literal: true

require 'rails_helper'

# EVO-1751: the update_custom_attribute automation action sets/updates a custom
# attribute value, routing by the definition's attribute_model so one action
# covers conversation, contact and pipeline-item attributes. Exercised through
# the simple modal executor (AutomationRules::ActionService).
RSpec.describe AutomationRules::ActionService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  def build_rule(key:, model:, value:)
    rule = AutomationRule.new(
      name: "rule-#{SecureRandom.hex(4)}",
      event_name: 'conversation_updated',
      active: true,
      mode: 'simple',
      conditions: [],
      actions: [{
        'action_name' => 'update_custom_attribute',
        'action_params' => [{
          'custom_attribute_key' => key,
          'custom_attribute_model' => model,
          'custom_attribute_value' => value
        }]
      }]
    )
    rule.save!
    rule
  end

  after { Current.reset }

  describe '#update_custom_attribute' do
    it 'is accepted by the model action whitelist (AC1)' do
      expect { build_rule(key: 'plan', model: 'conversation_attribute', value: 'premium') }.not_to raise_error
    end

    it 'sets a conversation custom attribute' do
      CustomAttributeDefinition.create!(attribute_display_name: 'Plan', attribute_key: 'plan',
                                        attribute_display_type: 'text', attribute_model: 'conversation_attribute')
      rule = build_rule(key: 'plan', model: 'conversation_attribute', value: 'premium')

      described_class.new(rule, nil, conversation).perform

      expect(conversation.reload.custom_attributes['plan']).to eq('premium')
    end

    it 'sets a contact custom attribute via the conversation contact' do
      CustomAttributeDefinition.create!(attribute_display_name: 'CPF', attribute_key: 'cpf',
                                        attribute_display_type: 'text', attribute_model: 'contact_attribute')
      rule = build_rule(key: 'cpf', model: 'contact_attribute', value: '123.456.789-00')

      described_class.new(rule, nil, conversation).perform

      expect(contact.reload.custom_attributes['cpf']).to eq('123.456.789-00')
    end

    it 'sets a pipeline-item custom field on the conversation pipeline item' do
      pipeline = Pipeline.create!(name: 'Sales', pipeline_type: 'custom', created_by: user)
      stage = PipelineStage.create!(pipeline: pipeline, name: 'New', position: 1)
      PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)
      CustomAttributeDefinition.create!(attribute_display_name: 'Deal value', attribute_key: 'deal_value',
                                        attribute_display_type: 'number', attribute_model: 'pipeline_item_attribute')
      rule = build_rule(key: 'deal_value', model: 'pipeline_item_attribute', value: '5000')

      described_class.new(rule, nil, conversation).perform

      expect(conversation.pipeline_items.first.reload.custom_fields['deal_value']).to eq('5000')
    end

    it 'is a no-op when no matching attribute definition exists' do
      rule = build_rule(key: 'ghost', model: 'contact_attribute', value: 'x')

      described_class.new(rule, nil, conversation).perform

      expect(contact.reload.custom_attributes).to eq({})
    end

    it 'does not collide when the same key exists for a different model' do
      CustomAttributeDefinition.create!(attribute_display_name: 'Score (contact)', attribute_key: 'score',
                                        attribute_display_type: 'number', attribute_model: 'contact_attribute')
      CustomAttributeDefinition.create!(attribute_display_name: 'Score (conversation)', attribute_key: 'score',
                                        attribute_display_type: 'number', attribute_model: 'conversation_attribute')
      rule = build_rule(key: 'score', model: 'conversation_attribute', value: '42')

      described_class.new(rule, nil, conversation).perform

      expect(conversation.reload.custom_attributes['score']).to eq('42')
      expect(contact.reload.custom_attributes).to eq({})
    end

    it 'stores a checkbox attribute as a real boolean, not the string "false"' do
      CustomAttributeDefinition.create!(attribute_display_name: 'Onboarded', attribute_key: 'onboarded',
                                        attribute_display_type: 'checkbox', attribute_model: 'conversation_attribute')
      rule = build_rule(key: 'onboarded', model: 'conversation_attribute', value: 'false')

      described_class.new(rule, nil, conversation).perform

      expect(conversation.reload.custom_attributes['onboarded']).to eq(false)
    end
  end
end
