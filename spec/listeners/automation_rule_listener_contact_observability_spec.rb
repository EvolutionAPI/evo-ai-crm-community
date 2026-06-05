# frozen_string_literal: true

require 'rails_helper'

# Regression (T2 / observabilidade): rule de contato com condição de CONVERSA e
# contato sem conversa deve gravar um run `skipped` (antes era drop silencioso).
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

  it 'records a skipped run for a conversation-scoped condition when the contact has no conversation (T2)' do
    # `status` is a conversation attribute -> routes to the conversation branch.
    build_rule([{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['open'], 'query_operator' => nil }])
    expect { dispatch({ 'name' => %w[a b] }) }.to change(AutomationRuleRun, :count).by(1)
    run = AutomationRuleRun.last
    expect(run.status).to eq('skipped')
    expect(run.steps.map { |s| s['label'] }.join).to include('no conversation')
  end

end
