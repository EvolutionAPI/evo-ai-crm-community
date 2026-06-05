# frozen_string_literal: true

require 'rails_helper'

# Integration coverage for contact-triggered automation rules under
# AutomationRuleListener#contact_updated.
#
# Regression: contact_created/contact_updated rules with only-contact (or no)
# conditions used to run through a webhook-only branch that recorded NOTHING in
# automation_rule_runs, so every contact automation was invisible in the logs.
# This spec asserts the run is now persisted (matched / no_match) and that
# conversation-bound actions are skipped with a recorded reason.
RSpec.describe AutomationRuleListener do
  let(:listener) { described_class.instance }

  let(:contact) { Contact.create!(name: 'Jane', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let!(:label) { Label.create!(title: 'vip', color: '#abcdef') }

  ContactEvent = Struct.new(:data) unless defined?(ContactEvent)

  def build_rule(actions:, conditions: [])
    rule = AutomationRule.new(
      name: "rule-#{SecureRandom.hex(4)}",
      event_name: 'contact_updated',
      active: true,
      mode: 'simple',
      conditions: conditions,
      actions: actions
    )
    rule.save!(validate: false)
    rule
  end

  def dispatch(changed_attributes: { 'name' => %w[Old New] })
    listener.contact_updated(ContactEvent.new({ contact: contact, changed_attributes: changed_attributes }))
  end

  after { Current.reset }

  describe 'native contact action with NO conditions' do
    let!(:rule) { build_rule(actions: [{ 'action_name' => 'add_label', 'action_params' => [label.id] }]) }

    it 'executes the action and records a matched run' do
      expect { dispatch }.to change(AutomationRuleRun, :count).by(1)

      run = AutomationRuleRun.last
      expect(run.status).to eq('matched')
      expect(run.event_name).to eq('contact_updated')
      expect(run.steps.map { |s| s['label'] }).to include('Action: add_label')
      expect(contact.reload.label_list).to include('vip')
    end
  end

  describe 'conversation-bound action on a contact trigger' do
    let!(:rule) { build_rule(actions: [{ 'action_name' => 'assign_team', 'action_params' => [SecureRandom.uuid] }]) }

    it 'records a matched run with a skip step explaining the missing conversation' do
      expect { dispatch }.to change(AutomationRuleRun, :count).by(1)

      run = AutomationRuleRun.last
      expect(run.status).to eq('matched')
      skip_step = run.steps.find { |s| s['label'] == 'Action skipped: assign_team' }
      expect(skip_step).to be_present
      expect(skip_step.dig('data', 'reason')).to include('requires a conversation')
    end
  end

  describe 'conditions that do not match' do
    let!(:rule) do
      build_rule(
        actions: [{ 'action_name' => 'add_label', 'action_params' => [label.id] }],
        conditions: [{ 'attribute_key' => 'name', 'filter_operator' => 'equal_to', 'values' => ['Someone Else'], 'query_operator' => nil }]
      )
    end

    it 'records a no_match run and does not execute the action' do
      expect { dispatch }.to change(AutomationRuleRun, :count).by(1)

      run = AutomationRuleRun.last
      expect(run.status).to eq('no_match')
      expect(contact.reload.label_list).not_to include('vip')
    end
  end

  describe 'guard: empty changed_attributes' do
    let!(:rule) { build_rule(actions: [{ 'action_name' => 'add_label', 'action_params' => [label.id] }]) }

    it 'does not record a run (event carries no change)' do
      expect { dispatch(changed_attributes: {}) }.not_to change(AutomationRuleRun, :count)
    end
  end
end
