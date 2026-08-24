# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutomationRuleListener, '#pipeline_stage_updated' do
  include ActiveJob::TestHelper

  let(:listener) { described_class.instance }

  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://crm258.example.com') }
  let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
  let(:contact) do
    Contact.create!(name: 'Lead Checkout', email: "lead-#{SecureRandom.hex(4)}@test.com",
                    phone_number: "+5571#{rand(100_000_000..999_999_999)}")
  end
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let(:pipeline) { Pipeline.create!(name: "funil-#{SecureRandom.hex(3)}", pipeline_type: 'custom', created_by: user) }
  let!(:entry_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Entrada', position: 1) }
  let!(:next_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Qualificado', position: 2) }
  let!(:ia_label) { Label.create!(title: "ia-#{SecureRandom.hex(3)}", color: '#00aabb') }

  def build_rule(conditions: [], actions: nil)
    rule = AutomationRule.new(
      name: "entrada-#{SecureRandom.hex(4)}",
      event_name: 'pipeline_stage_updated',
      active: true,
      mode: 'simple',
      conditions: conditions,
      actions: actions || [{ 'action_name' => 'add_label', 'action_params' => [ia_label.title] }]
    )
    rule.save!(validate: false)
    rule
  end

  def entered_entry_stage
    { 'pipeline_stage_id' => [nil, entry_stage.id] }
  end

  def entered_stage_condition
    { 'attribute_key' => 'pipeline_stage_id', 'filter_operator' => 'attribute_changed',
      'values' => { 'from' => [], 'to' => [entry_stage.id] }, 'query_operator' => nil }
  end

  def conversation_condition
    { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['open'], 'query_operator' => nil }
  end

  def contact_card
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: entry_stage, contact: contact, entered_at: Time.current)
  end

  def conversation_card
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: entry_stage, conversation: conversation, entered_at: Time.current)
  end

  # A conversation may hold one card per pipeline (unique index is per pipeline).
  def conversation_card_in_other_pipeline
    other = Pipeline.create!(name: "outro-#{SecureRandom.hex(3)}", pipeline_type: 'custom', created_by: user)
    stage = PipelineStage.create!(pipeline: other, name: 'Entrada', position: 1)
    [other, PipelineItem.create!(pipeline: other, pipeline_stage: stage, conversation: conversation, entered_at: Time.current)]
  end

  # Anonymous so the suite does not carry a top-level StageEvent constant.
  let(:stage_event) { Struct.new(:data) }

  def dispatch(pipeline_item, changed_attributes = entered_entry_stage, extra = {})
    listener.pipeline_stage_updated(
      stage_event.new({ pipeline_item: pipeline_item, changed_attributes: changed_attributes }.merge(extra))
    )
  end

  def runs_for(rule)
    AutomationRuleRun.where(automation_rule_id: rule.id).order(:started_at)
  end

  def step_labels(run)
    run.steps.map { |s| s['label'] }.join(' | ')
  end

  after { Current.reset }

  describe 'card criado a partir de contato' do
    it 'avalia as condicoes e aplica a acao no contato' do
      rule = build_rule(conditions: [entered_stage_condition])
      item = contact_card
      runs_for(rule).delete_all

      expect { dispatch(item) }.to change { runs_for(rule).count }.by(1)

      run = runs_for(rule).last
      expect(run.status).to eq('matched')
      expect(step_labels(run)).to include('Conditions evaluated')
      expect(contact.reload.label_list).to include(ia_label.title)
    end

    it 'registra o pipeline_item e o contato no payload do run' do
      rule = build_rule
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.payload).to include(
        'pipeline_item_id' => item.id, 'conversation_id' => nil, 'contact_id' => contact.id
      )
    end

    it 'nao dispara quando a condicao aponta para outro estagio' do
      rule = build_rule(conditions: [entered_stage_condition])
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item, { 'pipeline_stage_id' => [entry_stage.id, next_stage.id] })

      expect(runs_for(rule).last.status).to eq('no_match')
      expect(contact.reload.label_list).to be_empty
    end

    it 'dispara tambem na movimentacao entre estagios' do
      rule = build_rule
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item, { 'pipeline_stage_id' => [entry_stage.id, next_stage.id] })

      expect(runs_for(rule).last.status).to eq('matched')
      expect(contact.reload.label_list).to include(ia_label.title)
    end

    it 'recusa a regra de condicao de conversa com o motivo especifico' do
      rule = build_rule(conditions: [conversation_condition])
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item)

      run = runs_for(rule).last
      expect(run.status).to eq('skipped')
      expect(step_labels(run)).to include('conversation-scoped conditions')
      expect(step_labels(run)).not_to include('Conditions evaluated')
    end

    it 'registra a acao presa a conversa como skipped em vez de some-la' do
      rule = build_rule(actions: [{ 'action_name' => 'send_message', 'action_params' => ['oi'] }])
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(step_labels(runs_for(rule).last)).to include('Action skipped: send_message')
    end

    it 'aceita condicao de pipeline_id resolvida pelo card do evento' do
      rule = build_rule(conditions: [{ 'attribute_key' => 'pipeline_id', 'filter_operator' => 'equal_to',
                                       'values' => [pipeline.id], 'query_operator' => nil }])
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('matched')
    end

    it 'nao casa pipeline_id por causa de um card do contato em outro funil' do
      other_pipeline = Pipeline.create!(name: "outro-#{SecureRandom.hex(3)}", pipeline_type: 'custom', created_by: user)
      other_stage = PipelineStage.create!(pipeline: other_pipeline, name: 'Entrada', position: 1)
      PipelineItem.create!(pipeline: other_pipeline, pipeline_stage: other_stage, contact: contact, entered_at: Time.current)
      rule = build_rule(conditions: [{ 'attribute_key' => 'pipeline_id', 'filter_operator' => 'not_equal_to',
                                       'values' => [pipeline.id], 'query_operator' => nil }])
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('no_match')
      expect(contact.reload.label_list).to be_empty
    end

    it 'casa pipeline_id is_present pelo card do evento' do
      rule = build_rule(conditions: [{ 'attribute_key' => 'pipeline_id', 'filter_operator' => 'is_present',
                                       'values' => [], 'query_operator' => nil }])
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('matched')
    end

    it 'pipeline_id is_not_present nao casa enquanto o card do evento existe' do
      rule = build_rule(conditions: [{ 'attribute_key' => 'pipeline_id', 'filter_operator' => 'is_not_present',
                                       'values' => [], 'query_operator' => nil }])
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('no_match')
      expect(contact.reload.label_list).to be_empty
    end

    it 'aceita condicao de custom attribute de contato' do
      definition = CustomAttributeDefinition.create!(
        attribute_key: "plano_#{SecureRandom.hex(3)}", attribute_display_name: 'Plano',
        attribute_model: 'contact_attribute', attribute_display_type: 'text'
      )
      key = definition.attribute_key
      contact.update!(custom_attributes: { key => 'gold' })
      Current.reset
      rule = build_rule(conditions: [{ 'attribute_key' => key, 'custom_attribute_type' => 'contact_attribute',
                                       'filter_operator' => 'equal_to', 'values' => ['gold'], 'query_operator' => nil }])
      item = contact_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('matched')
      expect(contact.reload.label_list).to include(ia_label.title)
    end
  end

  describe 'card de conversa (comportamento preservado)' do
    it 'casa e aplica a label na conversa' do
      rule = build_rule
      item = conversation_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('matched')
      expect(conversation.reload.label_list).to include(ia_label.title)
    end

    it 'condicao de conversa continua sendo avaliada' do
      rule = build_rule(conditions: [conversation_condition])
      item = conversation_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('matched')
    end

    it 'filtro pipeline_id casa em vez de quebrar em conversations.pipeline_id' do
      rule = build_rule(conditions: [{ 'attribute_key' => 'pipeline_id', 'filter_operator' => 'equal_to',
                                       'values' => [pipeline.id], 'query_operator' => nil }])
      item = conversation_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('matched')
    end

    it 'nao casa pipeline_id por causa de um card da conversa em outro funil' do
      other_pipeline, = conversation_card_in_other_pipeline
      rule = build_rule(conditions: [{ 'attribute_key' => 'pipeline_id', 'filter_operator' => 'equal_to',
                                       'values' => [other_pipeline.id], 'query_operator' => nil }])
      item = conversation_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('no_match')
      expect(conversation.reload.label_list).to be_empty
    end

    it 'pipeline_id not_equal_to olha so o card que disparou o evento' do
      conversation_card_in_other_pipeline
      rule = build_rule(conditions: [{ 'attribute_key' => 'pipeline_id', 'filter_operator' => 'not_equal_to',
                                       'values' => [pipeline.id], 'query_operator' => nil }])
      item = conversation_card
      runs_for(rule).delete_all

      dispatch(item)

      expect(runs_for(rule).last.status).to eq('no_match')
      expect(conversation.reload.label_list).to be_empty
    end
  end

  describe 'promocao do card de lead' do
    it 'redispara a entrada no estagio quando a conversa chega' do
      rule = build_rule(conditions: [conversation_condition])
      item = contact_card
      runs_for(rule).delete_all

      perform_enqueued_jobs { conversation }

      expect(item.reload.conversation_id).to eq(conversation.id)
      expect(runs_for(rule).map(&:status)).to include('matched')
      expect(conversation.reload.label_list).to include(ia_label.title)
    end

    it 'nao aplica a acao duas vezes no fluxo real de promocao' do
      rule = build_rule
      item = contact_card
      runs_for(rule).delete_all

      perform_enqueued_jobs { conversation }

      expect(item.reload.conversation_id).to eq(conversation.id)
      expect(conversation.reload.label_list).to be_empty
      expect(runs_for(rule).map(&:status)).to eq(%w[skipped])
    end

    it 'o replay nao e engolido pela janela de dedup' do
      rule = build_rule(conditions: [conversation_condition])
      item = contact_card
      item.update!(conversation_id: conversation.id, contact_id: nil)
      allow(Rails.cache).to receive(:exist?).and_return(true)
      runs_for(rule).delete_all

      dispatch(item, entered_entry_stage, { promoted_from_lead_card: true })

      expect(runs_for(rule).last.status).to eq('matched')
    end

    it 'o evento normal continua respeitando a janela de dedup' do
      rule = build_rule
      item = conversation_card
      allow(Rails.cache).to receive(:exist?).and_return(true)
      runs_for(rule).delete_all

      dispatch(item)

      expect(step_labels(runs_for(rule).last)).to include('Duplicate event')
    end

    it 'nao repete a regra que ja rodou no eixo do contato' do
      rule = build_rule
      item = contact_card
      item.update!(conversation_id: conversation.id, contact_id: nil)
      runs_for(rule).delete_all

      dispatch(item, entered_entry_stage, { promoted_from_lead_card: true })

      run = runs_for(rule).last
      expect(run.status).to eq('skipped')
      expect(step_labels(run)).to include('Runs on the contact axis')
      expect(run.payload).to include('pipeline_item_id' => item.id, 'conversation_id' => conversation.id)
    end
  end

  describe 'predicado de roteamento' do
    it 'aceita condicao de contato, de estagio e de pipeline' do
      rule = build_rule(conditions: [entered_stage_condition,
                                     { 'attribute_key' => 'name', 'filter_operator' => 'equal_to',
                                       'values' => ['Lead Checkout'], 'query_operator' => nil }])

      expect(listener.send(:pipeline_rule_executable_without_conversation?, rule)).to be(true)
    end

    it 'aceita custom attribute de contato' do
      rule = build_rule(conditions: [{ 'attribute_key' => 'plano', 'custom_attribute_type' => 'contact_attribute',
                                       'filter_operator' => 'equal_to', 'values' => ['gold'], 'query_operator' => nil }])

      expect(listener.send(:pipeline_rule_executable_without_conversation?, rule)).to be(true)
    end

    it 'recusa condicao de conversa' do
      rule = build_rule(conditions: [entered_stage_condition, conversation_condition])

      expect(listener.send(:pipeline_rule_executable_without_conversation?, rule)).to be(false)
    end
  end
end
