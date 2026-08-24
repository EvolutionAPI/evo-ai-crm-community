# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutomationRuleListener, '#pipeline_stage_updated' do
  include ActiveJob::TestHelper

  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://e2e.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
  let!(:ia_label) { Label.create!(title: "ia-#{SecureRandom.hex(3)}", color: '#00aabb') }
  let!(:pipeline) do
    Pipeline.create!(name: "funil-#{SecureRandom.hex(3)}", pipeline_type: 'custom', created_by: user, is_default: true)
  end
  let!(:entry_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Entrada', position: 1) }
  let!(:won_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Ganho', position: 2) }

  def rule!(conditions:, actions:)
    rule = AutomationRule.new(name: "r-#{SecureRandom.hex(4)}", event_name: 'pipeline_stage_updated',
                              active: true, mode: 'simple', conditions: conditions, actions: actions)
    rule.save!(validate: false)
    rule
  end

  def entry_rule
    rule!(conditions: [{ 'attribute_key' => 'pipeline_stage_id', 'filter_operator' => 'attribute_changed',
                         'values' => { 'from' => [], 'to' => [entry_stage.id] }, 'query_operator' => nil }],
          actions: [{ 'action_name' => 'add_label', 'action_params' => [ia_label.title] }])
  end

  def runs(rule) = AutomationRuleRun.where(automation_rule_id: rule.id).order(:started_at)

  # Automation-path jobs only: avatar and ip lookup make real HTTP calls, which the
  # WebMock of other specs in the same lane blocks.
  def run_automation_jobs(&)
    perform_enqueued_jobs(only: [EventDispatcherJob, AutomationContactEventJob], &)
  end

  after { Current.reset }

  it 'contato criado cai no funil default e a automacao de entrada roda' do
    r = entry_rule
    contact = nil
    run_automation_jobs do
      contact = Contact.create!(name: 'Pedro', email: "p-#{SecureRandom.hex(4)}@t.com",
                                phone_number: "+5571#{rand(100_000_000..999_999_999)}")
    end
    item = PipelineItem.find_by(contact_id: contact.id)
    expect(item).to be_present
    expect(item.conversation_id).to be_nil
    expect(runs(r).map(&:status)).to eq(['matched'])
    expect(contact.reload.label_list).to include(ia_label.title)
  end

  it 'lead via API publica (checkout) dispara a automacao de entrada' do
    r = entry_rule
    contact = Contact.create!(name: 'Checkout', email: "c-#{SecureRandom.hex(4)}@t.com",
                              phone_number: "+5571#{rand(100_000_000..999_999_999)}",
                              skip_default_pipeline_assignment: true)
    Current.reset
    runs(r).delete_all
    item = nil
    run_automation_jobs do
      item = pipeline.pipeline_items.create!(contact: contact, conversation: nil, pipeline_stage: entry_stage,
                                             entered_at: Time.current,
                                             custom_fields: { 'lead_source' => 'public_api' })
    end
    expect(runs(r).map(&:status)).to eq(['matched'])
    expect(contact.reload.label_list).to include(ia_label.title)
  end

  it 'mover o card de contato entre estagios dispara a regra do estagio destino' do
    won_label = Label.create!(title: "ganho-#{SecureRandom.hex(3)}", color: '#00ff00')
    r = rule!(conditions: [{ 'attribute_key' => 'pipeline_stage_id', 'filter_operator' => 'attribute_changed',
                             'values' => { 'from' => [], 'to' => [won_stage.id] }, 'query_operator' => nil }],
              actions: [{ 'action_name' => 'add_label', 'action_params' => [won_label.title] }])
    contact = Contact.create!(name: 'Move', email: "m-#{SecureRandom.hex(4)}@t.com",
                              phone_number: "+5571#{rand(100_000_000..999_999_999)}",
                              skip_default_pipeline_assignment: true)
    Current.reset
    item = pipeline.pipeline_items.create!(contact: contact, pipeline_stage: entry_stage, entered_at: Time.current)
    runs(r).delete_all
    run_automation_jobs { item.update!(pipeline_stage: won_stage) }
    expect(runs(r).map(&:status)).to eq(['matched'])
    expect(contact.reload.label_list).to include(won_label.title)
  end

  it 'promocao roda a regra de conversa e nao repete a de contato' do
    contact_rule = entry_rule
    conv_label = Label.create!(title: "conv-#{SecureRandom.hex(3)}", color: '#0000ff')
    conv_rule = rule!(conditions: [{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to',
                                     'values' => ['open'], 'query_operator' => nil }],
                      actions: [{ 'action_name' => 'add_label', 'action_params' => [conv_label.title] }])
    contact = nil
    run_automation_jobs do
      contact = Contact.create!(name: 'Promo', email: "pr-#{SecureRandom.hex(4)}@t.com",
                                phone_number: "+5571#{rand(100_000_000..999_999_999)}")
    end
    item = PipelineItem.find_by(contact_id: contact.id)
    labels_after_entry = contact.reload.label_list

    ci = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4))
    conversation = nil
    run_automation_jobs { conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: ci) }

    item.reload

    expect(item.conversation_id).to eq(conversation.id)
    expect(labels_after_entry).to include(ia_label.title)
    expect(runs(contact_rule).map(&:status)).to eq(%w[matched skipped])
    expect(runs(conv_rule).map(&:status)).to eq(%w[skipped matched])
    expect(conversation.reload.label_list).to include(conv_label.title)
    expect(conversation.reload.label_list).not_to include(ia_label.title)
  end

  it 'regra de condicao de conversa em card sem conversa fica skipped com motivo' do
    r = rule!(conditions: [{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to',
                             'values' => ['open'], 'query_operator' => nil }],
              actions: [{ 'action_name' => 'add_label', 'action_params' => [ia_label.title] }])
    contact = nil
    run_automation_jobs do
      contact = Contact.create!(name: 'Skip', email: "s-#{SecureRandom.hex(4)}@t.com",
                                phone_number: "+5571#{rand(100_000_000..999_999_999)}")
    end
    run = runs(r).last
    expect(run.status).to eq('skipped')
    expect(run.steps.map { |s| s['label'] }.join).to include('conversation-scoped conditions')
    expect(contact.reload.label_list).to be_empty
  end

  it 'card de conversa segue igual (nao-regressao)' do
    r = entry_rule
    contact = Contact.create!(name: 'Conv', email: "cv-#{SecureRandom.hex(4)}@t.com",
                              phone_number: "+5571#{rand(100_000_000..999_999_999)}",
                              skip_default_pipeline_assignment: true)
    Current.reset
    ci = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4))
    conversation = nil
    run_automation_jobs { conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: ci) }
    item = PipelineItem.find_by(conversation_id: conversation.id)
    expect(item.read_attribute(:contact_id)).to be_nil
    expect(runs(r).map(&:status)).to eq(['matched'])
    expect(conversation.reload.label_list).to include(ia_label.title)
  end
end
