# frozen_string_literal: true

require 'rails_helper'

# Regression for the contact-path condition evaluator: attribute_changed and
# starts_with used to fall through to `else false` (silent never-match), and
# `labels equal_to` used all-of semantics while the SQL path uses any-of.
RSpec.describe AutomationRuleListener do
  let(:listener) { described_class.instance }
  let(:contact) { Contact.create!(name: 'Jane', email: "c-#{SecureRandom.hex(4)}@test.com", phone_number: '+5571999998888') }
  let!(:vip) { Label.create!(title: 'vip', color: '#abcdef') }
  let!(:gold) { Label.create!(title: 'gold', color: '#ffd700') }

  ContactCondEvent = Struct.new(:data) unless defined?(ContactCondEvent)

  def build_rule(conditions)
    rule = AutomationRule.new(
      name: "rule-#{SecureRandom.hex(4)}", event_name: 'contact_updated', active: true, mode: 'simple',
      conditions: conditions, actions: [{ 'action_name' => 'send_webhook_event', 'action_params' => ['https://e.com/h'] }]
    )
    rule.save!(validate: false)
    rule
  end

  def dispatch(changed_attributes)
    listener.contact_updated(ContactCondEvent.new({ contact: contact, changed_attributes: changed_attributes }))
  end

  after { Current.reset }
  before { allow(WebhookJob).to receive(:perform_later) }

  it 'matches blocked attribute_changed (false -> true)' do
    build_rule([{ 'attribute_key' => 'blocked', 'filter_operator' => 'attribute_changed', 'values' => { 'from' => ['false'], 'to' => ['true'] }, 'query_operator' => nil }])
    dispatch({ 'blocked' => [false, true] })
    expect(AutomationRuleRun.last.status).to eq('matched')
  end

  it 'matches labels attribute_changed when the requested label was added' do
    build_rule([{ 'attribute_key' => 'labels', 'filter_operator' => 'attribute_changed', 'values' => { 'from' => [], 'to' => [vip.id] }, 'query_operator' => nil }])
    dispatch({ 'label_list' => [[], ['vip']] })
    expect(AutomationRuleRun.last.status).to eq('matched')
  end

  it 'matches phone_number starts_with' do
    build_rule([{ 'attribute_key' => 'phone_number', 'filter_operator' => 'starts_with', 'values' => ['+55'], 'query_operator' => nil }])
    dispatch({ 'name' => %w[a b] })
    expect(AutomationRuleRun.last.status).to eq('matched')
  end

  it 'labels equal_to is any-of: matches when the contact has ANY requested label' do
    contact.update!(label_list: ['vip']) # has vip, not gold
    Current.reset
    build_rule([{ 'attribute_key' => 'labels', 'filter_operator' => 'equal_to', 'values' => [vip.id, gold.id], 'query_operator' => nil }])
    dispatch({ 'name' => %w[a b] })
    expect(AutomationRuleRun.last.status).to eq('matched')
  end

  it 'records a no_match run when an attribute_changed transition does not match' do
    build_rule([{ 'attribute_key' => 'blocked', 'filter_operator' => 'attribute_changed', 'values' => { 'from' => ['true'], 'to' => ['false'] }, 'query_operator' => nil }])
    dispatch({ 'blocked' => [false, true] }) # opposite direction
    expect(AutomationRuleRun.last.status).to eq('no_match')
  end

  # Seam test (review ressalva): drive the condition with the changed_attributes a
  # REAL update!(label_list:) actually emits, instead of hand-injecting
  # {'label_list' => [[], ['vip']]}. This exercises the producer→consumer seam
  # (acts-as-taggable-on writes label_list into previous_changes).
  it 'matches labels attribute_changed using previous_changes from a real update!(label_list:)' do
    build_rule([{ 'attribute_key' => 'labels', 'filter_operator' => 'attribute_changed', 'values' => { 'from' => [], 'to' => [vip.id] }, 'query_operator' => nil }])
    contact.update!(label_list: ['vip'])
    Current.reset
    real_changes = contact.previous_changes.as_json
    expect(real_changes).to have_key('label_list') # producer side actually carries it
    dispatch(real_changes)
    expect(AutomationRuleRun.last.status).to eq('matched')
  end

  # Shape guard (review suggestion): a malformed `values` (bare Array instead of
  # {from,to}) must fail THIS condition as no_match, not raise a TypeError that
  # errors the whole rule run.
  it 'records a no_match (not error) when an attribute_changed condition has a malformed values shape' do
    build_rule([{ 'attribute_key' => 'labels', 'filter_operator' => 'attribute_changed', 'values' => [vip.id], 'query_operator' => nil }])
    dispatch({ 'label_list' => [[], ['vip']] })
    expect(AutomationRuleRun.last.status).to eq('no_match')
  end
end
