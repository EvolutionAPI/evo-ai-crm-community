# frozen_string_literal: true

require 'rails_helper'

# EVO-2202: an archived pipeline is hidden from every picker, but a rule written months ago
# kept dragging conversations into it. The guard lives in the shared PipelineActionHandlers
# module, so it covers both executor surfaces (modal-style ActionService and flow-canvas
# FlowExecutionService) at once.
RSpec.describe 'Automation rule pipeline actions on an archived pipeline' do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let(:target) { Pipeline.create!(name: 'Target', pipeline_type: 'custom', created_by: user) }
  let!(:target_stage) { PipelineStage.create!(pipeline: target, name: 'T1', position: 1) }

  def rule_with(action_name, params)
    AutomationRule.create!(
      name: "Rule #{SecureRandom.hex(3)}",
      event_name: 'conversation_created',
      conditions: [],
      actions: [{ 'action_name' => action_name, 'action_params' => params }],
      active: true
    )
  end

  after { Current.reset }

  describe 'assign_to_pipeline' do
    let(:rule) { rule_with('assign_to_pipeline', [target.id]) }

    it 'adds the conversation while the pipeline is active' do
      expect { described_class_service(rule).perform }
        .to change { conversation.reload.pipeline_items.count }.by(1)
    end

    it 'refuses to add it once the pipeline is archived' do
      target.update!(is_active: false)

      expect { described_class_service(rule).perform }
        .not_to change { conversation.reload.pipeline_items.count }
    end

    # execute_pipeline_assignment starts with destroy_all, and pipeline_items are
    # hard-deleted: reaching it would wipe the conversation's other memberships.
    it 'does not wipe the memberships the conversation already has' do
      other = Pipeline.create!(name: 'Other', pipeline_type: 'custom', created_by: user)
      other_stage = PipelineStage.create!(pipeline: other, name: 'O1', position: 1)
      PipelineItem.create!(pipeline: other, pipeline_stage: other_stage, conversation: conversation)
      target.update!(is_active: false)

      expect { described_class_service(rule).perform }
        .not_to change { conversation.reload.pipeline_items.count }
    end

    it 'logs the refusal with the pipeline id and the action' do
      target.update!(is_active: false)
      allow(Rails.logger).to receive(:warn)

      described_class_service(rule).perform

      expect(Rails.logger).to have_received(:warn).with(/#{target.id} is archived.*assign_to_pipeline/m)
    end
  end

  describe 'update_pipeline_stage' do
    let(:rule) { rule_with('update_pipeline_stage', [target_stage.id]) }

    it 'moves the conversation while the pipeline is active' do
      expect { described_class_service(rule).perform }
        .to change { conversation.reload.pipeline_items.count }.by(1)
    end

    it 'refuses once the destination pipeline is archived' do
      target.update!(is_active: false)

      expect { described_class_service(rule).perform }
        .not_to change { conversation.reload.pipeline_items.count }
    end
  end

  # The operator reads the rule's execution timeline, not the server log — and the listener
  # records every action as `success` BEFORE running it, so without this step a refused
  # action would show up green.
  describe 'execution timeline' do
    let(:rule) { rule_with('assign_to_pipeline', [target.id]) }
    let(:recorder) do
      ::AutomationRules::RunRecorder.new(rule: rule, event_name: 'conversation_created', payload: {})
    end

    it 'records the refusal as a warning step' do
      target.update!(is_active: false)

      AutomationRules::ActionService.new(rule, nil, conversation, recorder: recorder).perform
      recorder.matched!
      recorder.persist!

      run = AutomationRuleRun.where(automation_rule_id: rule.id).last
      skipped = run.steps.find { |s| s['label'].to_s.include?('Skipped: assign_to_pipeline') }
      expect(skipped).to be_present
      expect(skipped['level']).to eq('warn')
      expect(skipped.dig('data', 'reason')).to eq('pipeline_archived')
    end

    # The timeline records "Action: ..." as success before the action runs; a bare skip
    # step would be contradicted by a green Matched result, so a refused action downgrades
    # the run status to skipped.
    it 'downgrades the run status so it does not read as a clean match' do
      target.update!(is_active: false)

      AutomationRules::ActionService.new(rule, nil, conversation, recorder: recorder).perform
      recorder.matched!
      recorder.persist!

      expect(AutomationRuleRun.where(automation_rule_id: rule.id).last.status).to eq('skipped')
    end

    it 'records nothing extra and keeps a clean match while the pipeline is active' do
      AutomationRules::ActionService.new(rule, nil, conversation, recorder: recorder).perform
      recorder.matched!
      recorder.persist!

      run = AutomationRuleRun.where(automation_rule_id: rule.id).last
      expect(run.steps.map { |s| s['label'] }).not_to include(a_string_matching(/Skipped/))
      expect(run.status).to eq('matched')
    end
  end

  # The flow-canvas executor reaches the same handlers through execute_node_action, with
  # its own node_data normalisation, so the guard needs coverage on that surface too.
  describe 'flow-canvas surface' do
    let(:flow_rule) { rule_with('assign_to_pipeline', [target.id]) }
    let(:flow_service) { AutomationRules::FlowExecutionService.new(flow_rule, nil, conversation) }
    let(:node) { { 'type' => 'assign-to-pipeline-node', 'id' => 'n1', 'data' => { 'pipeline_id' => target.id } } }
    # move-to-pipeline-stage-node reaches update_pipeline_stage, whose archived guard sits on
    # the destination stage's pipeline. The auto-assign branch would otherwise push the
    # conversation into the archived board — cover it on the flow surface too, not only modal.
    let(:stage_node) do
      { 'type' => 'move-to-pipeline-stage-node', 'id' => 'n2', 'data' => { 'pipeline_stage_id' => target_stage.id } }
    end

    it 'refuses to assign through a flow node when the pipeline is archived' do
      target.update!(is_active: false)

      expect { flow_service.send(:execute_node_action, node) }
        .not_to change { conversation.reload.pipeline_items.count }
    end

    it 'assigns through a flow node while the pipeline is active' do
      expect { flow_service.send(:execute_node_action, node) }
        .to change { conversation.reload.pipeline_items.count }.by(1)
    end

    it 'refuses to move through a flow node when the destination pipeline is archived' do
      target.update!(is_active: false)

      expect { flow_service.send(:execute_node_action, stage_node) }
        .not_to change { conversation.reload.pipeline_items.count }
    end

    it 'moves through a flow node while the pipeline is active' do
      expect { flow_service.send(:execute_node_action, stage_node) }
        .to change { conversation.reload.pipeline_items.count }.by(1)
    end
  end

  # create_pipeline_task is deliberately NOT guarded: it acts on an item already inside the
  # pipeline and never pushes anything in (decision on EVO-2200 — do not touch what is
  # already there). This locks that intent: the archived guard must not fire for it.
  describe 'create_pipeline_task is intentionally not guarded' do
    it 'does not consult the archived-pipeline guard' do
      stage = PipelineStage.create!(pipeline: target, name: 'Held', position: 2)
      PipelineItem.create!(pipeline: target, pipeline_stage: stage, conversation: conversation)
      target.update!(is_active: false)
      rule = rule_with('create_pipeline_task', [{ title: 'Call the customer' }])
      service = AutomationRules::ActionService.new(rule, nil, conversation)

      expect(service).not_to receive(:skip_archived_pipeline)
      service.perform
    end
  end

  def described_class_service(rule)
    AutomationRules::ActionService.new(rule, nil, conversation)
  end
end
