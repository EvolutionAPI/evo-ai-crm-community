# frozen_string_literal: true

require 'rails_helper'

# Integration coverage for the full attribute_changed -> action flow under
# AutomationRuleListener#conversation_updated.
#
# Asserts that EVO-1058 wires up end-to-end: when a label is added (a
# `label_list` transition arrives via changed_attributes), an active rule
# configured with attribute_changed on labels triggers the action service
# exactly once per dispatch — not twice, not zero. The dedup of the
# label-change dispatch itself is covered separately in
# spec/models/conversation_label_dispatch_spec.rb; this spec exercises the
# listener -> ConditionsFilterService -> ActionService chain in isolation.

AttributeChangedEvent = Struct.new(:data) unless defined?(AttributeChangedEvent)

RSpec.describe AutomationRuleListener do
  let(:listener) { described_class.instance }

  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let!(:label_atleta) { Label.create!(title: 'atleta', color: '#abcdef') }

  def build_rule(conditions:, event_name: 'conversation_updated')
    rule = AutomationRule.new(
      name: "rule-#{SecureRandom.hex(4)}",
      event_name: event_name,
      active: true,
      mode: 'simple',
      conditions: conditions,
      actions: [{ 'action_name' => 'change_priority', 'action_params' => ['urgent'] }]
    )
    rule.save!(validate: false)
    rule
  end

  describe '#conversation_updated with attribute_changed on labels' do
    let!(:rule) do
      build_rule(
        conditions: [{
          'attribute_key' => 'labels',
          'filter_operator' => 'attribute_changed',
          'values' => { 'from' => [], 'to' => [label_atleta.id] },
          'query_operator' => nil
        }]
      )
    end

    it 'fires the action exactly once when the requested label was added in this update' do
      event = AttributeChangedEvent.new({
                                          conversation: conversation,
                                          changed_attributes: { 'label_list' => [[], ['atleta']] }
                                        })
      service_double = instance_double(AutomationRules::ActionService, perform: nil)
      expect(AutomationRules::ActionService).to receive(:new)
        .with(rule, nil, conversation, hash_including(:recorder)).once.and_return(service_double)
      expect(service_double).to receive(:perform).once

      listener.conversation_updated(event)
    end

    it 'does not fire when the watched label is not in the diff' do
      event = AttributeChangedEvent.new({
                                          conversation: conversation,
                                          changed_attributes: { 'label_list' => [[], ['outro']] }
                                        })
      expect(AutomationRules::ActionService).not_to receive(:new)

      listener.conversation_updated(event)
    end

    it 'does not fire when the watched label was already present (no transition)' do
      event = AttributeChangedEvent.new({
                                          conversation: conversation,
                                          changed_attributes: { 'label_list' => [['atleta'], %w[atleta outro]] }
                                        })
      expect(AutomationRules::ActionService).not_to receive(:new)

      listener.conversation_updated(event)
    end

    it 'does not fire (and does not crash) when label_list is absent from this update' do
      event = AttributeChangedEvent.new({
                                          conversation: conversation,
                                          changed_attributes: { 'priority' => [nil, 'urgent'] }
                                        })
      expect(AutomationRules::ActionService).not_to receive(:new)

      listener.conversation_updated(event)
    end

    it 'skips when the event was performed by automation (loop guard)' do
      another_rule = build_rule(conditions: [])
      event = AttributeChangedEvent.new({
                                          conversation: conversation,
                                          changed_attributes: { 'label_list' => [[], ['atleta']] },
                                          performed_by: another_rule
                                        })
      expect(AutomationRules::ActionService).not_to receive(:new)

      listener.conversation_updated(event)
    end
  end

  describe '#conversation_updated with attribute_changed on status (scalar path)' do
    let!(:rule) do
      build_rule(
        conditions: [{
          'attribute_key' => 'status',
          'filter_operator' => 'attribute_changed',
          'values' => { 'from' => ['open'], 'to' => ['resolved'] },
          'query_operator' => nil
        }]
      )
    end

    it 'fires once on the open -> resolved transition' do
      event = AttributeChangedEvent.new({
                                          conversation: conversation,
                                          changed_attributes: { 'status' => %w[open resolved] }
                                        })
      service_double = instance_double(AutomationRules::ActionService, perform: nil)
      expect(AutomationRules::ActionService).to receive(:new)
        .with(rule, nil, conversation, hash_including(:recorder)).once.and_return(service_double)
      expect(service_double).to receive(:perform).once

      listener.conversation_updated(event)
    end

    it 'does not fire on a different transition' do
      event = AttributeChangedEvent.new({
                                          conversation: conversation,
                                          changed_attributes: { 'status' => %w[open snoozed] }
                                        })
      expect(AutomationRules::ActionService).not_to receive(:new)

      listener.conversation_updated(event)
    end
  end
end
