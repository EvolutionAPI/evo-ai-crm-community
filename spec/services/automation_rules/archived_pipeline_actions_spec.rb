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
      recorder.persist!

      run = AutomationRuleRun.where(automation_rule_id: rule.id).last
      skipped = run.steps.find { |s| s['label'].to_s.include?('Skipped: assign_to_pipeline') }
      expect(skipped).to be_present
      expect(skipped['level']).to eq('warn')
      expect(skipped.dig('data', 'reason')).to eq('pipeline_archived')
    end

    it 'records nothing extra while the pipeline is active' do
      AutomationRules::ActionService.new(rule, nil, conversation, recorder: recorder).perform
      recorder.persist!

      run = AutomationRuleRun.where(automation_rule_id: rule.id).last
      expect(run.steps.map { |s| s['label'] }).not_to include(a_string_matching(/Skipped/))
    end
  end

  def described_class_service(rule)
    AutomationRules::ActionService.new(rule, nil, conversation)
  end
end
