# frozen_string_literal: true

require 'rails_helper'

# Unit coverage for the contact-native action executor used by
# AutomationRuleListener for contact_created / contact_updated rules that have
# no conversation in scope.
RSpec.describe AutomationRules::ContactActionService do
  let(:contact) { Contact.create!(name: 'Jane', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let!(:label) { Label.create!(title: 'vip', color: '#abcdef') }

  let(:recorder) { instance_double(AutomationRules::RunRecorder, add_step: nil) }

  def build_rule(actions:)
    rule = AutomationRule.new(
      name: "rule-#{SecureRandom.hex(4)}",
      event_name: 'contact_updated',
      active: true,
      mode: 'simple',
      conditions: [],
      actions: actions
    )
    rule.save!(validate: false)
    rule
  end

  after { Current.reset }

  describe 'native contact actions' do
    it 'enqueues a webhook with the contact payload' do
      allow(WebhookJob).to receive(:perform_later)
      rule = build_rule(actions: [{ 'action_name' => 'send_webhook_event', 'action_params' => ['https://example.com/hook '] }])

      described_class.new(rule, contact, recorder: recorder).perform

      expect(WebhookJob).to have_received(:perform_later).with(
        'https://example.com/hook', # whitespace trimmed
        hash_including(event: 'contact_updated')
      )
      expect(recorder).to have_received(:add_step).with('Action: send_webhook_event', hash_including(level: 'success'))
    end

    it 'adds a label to the contact (not a conversation)' do
      rule = build_rule(actions: [{ 'action_name' => 'add_label', 'action_params' => [label.id] }])

      described_class.new(rule, contact, recorder: recorder).perform

      expect(contact.reload.label_list).to include('vip')
    end

    it 'removes a label from the contact' do
      contact.update!(label_list: ['vip'])
      rule = build_rule(actions: [{ 'action_name' => 'remove_label', 'action_params' => [label.id] }])

      described_class.new(rule, contact, recorder: recorder).perform

      expect(contact.reload.label_list).not_to include('vip')
    end
  end

  describe 'conversation-bound actions' do
    it 'does NOT execute and records a skip with a reason' do
      rule = build_rule(actions: [{ 'action_name' => 'assign_team', 'action_params' => [SecureRandom.uuid] }])

      expect_any_instance_of(Conversation).not_to receive(:update!)
      described_class.new(rule, contact, recorder: recorder).perform

      expect(recorder).to have_received(:add_step).with(
        'Action skipped: assign_team',
        hash_including(level: 'warn', data: hash_including(reason: a_string_including('requires a conversation')))
      )
    end
  end

  describe 'robustness' do
    it 'isolates a failing action so later actions still run' do
      allow(WebhookJob).to receive(:perform_later)
      # First action raises (blank label set resolves to empty -> we force an error
      # by stubbing Label.where to raise on the first call only).
      rule = build_rule(actions: [
                          { 'action_name' => 'add_label', 'action_params' => [label.id] },
                          { 'action_name' => 'send_webhook_event', 'action_params' => ['https://example.com/hook'] }
                        ])
      allow(Label).to receive(:where).and_raise(StandardError, 'boom')
      allow(EvolutionExceptionTracker).to receive(:new).and_return(double(capture_exception: nil))

      described_class.new(rule, contact, recorder: recorder).perform

      # The webhook (second action) still fired despite the first raising.
      expect(WebhookJob).to have_received(:perform_later)
      expect(recorder).to have_received(:add_step).with('Action errored: add_label', hash_including(level: 'error'))
    end

    it 'resets Current.executed_by after running' do
      rule = build_rule(actions: [{ 'action_name' => 'add_label', 'action_params' => [label.id] }])

      described_class.new(rule, contact, recorder: recorder).perform

      expect(Current.executed_by).to be_nil
    end
  end
end
