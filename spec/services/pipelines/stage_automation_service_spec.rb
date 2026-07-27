# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pipelines::StageAutomationService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  let(:pipeline) { Pipeline.create!(name: 'Test Pipeline', pipeline_type: 'custom', created_by: user) }
  let(:stage_a) { PipelineStage.create!(pipeline: pipeline, name: 'Stage A', position: 1) }
  let(:stage_b) { PipelineStage.create!(pipeline: pipeline, name: 'Stage B', position: 2) }
  let!(:pipeline_item) do
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage_a, conversation: conversation)
  end

  subject(:service) { described_class.new(conversation, changed_attributes) }

  describe '#perform' do
    context 'with label_added trigger' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      context 'when trigger_value matches added label' do
        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                          'action' => 'move_to_stage', 'action_value' => stage_b.id }]
          })
        end

        it 'moves the conversation to the target stage' do
          expect { service.perform }.to change { pipeline_item.reload.pipeline_stage_id }.to(stage_b.id)
        end
      end

      context 'when trigger_value is blank (any label)' do
        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => '',
                          'action' => 'move_to_stage', 'action_value' => stage_b.id }]
          })
        end

        it 'moves the conversation regardless of label name' do
          expect { service.perform }.to change { pipeline_item.reload.pipeline_stage_id }.to(stage_b.id)
        end
      end

      context 'when trigger_value does not match' do
        let(:changed_attributes) { { 'label_list' => [[], ['low-priority']] } }

        before do
          stage_a.update!(automation_rules: {
            'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                          'action' => 'move_to_stage', 'action_value' => stage_b.id }]
          })
        end

        it 'does not move the conversation' do
          expect { service.perform }.not_to change { pipeline_item.reload.pipeline_stage_id }
        end
      end
    end

    context 'with conversation_status_changed trigger' do
      let(:changed_attributes) { { 'status' => ['open', 'resolved'] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'conversation_status_changed', 'trigger_value' => 'resolved',
                        'action' => 'move_to_stage', 'action_value' => stage_b.id }]
        })
      end

      it 'moves the conversation when status matches' do
        expect { service.perform }.to change { pipeline_item.reload.pipeline_stage_id }.to(stage_b.id)
      end

      context 'when status does not match' do
        let(:changed_attributes) { { 'status' => ['open', 'pending'] } }

        it 'does not move the conversation' do
          expect { service.perform }.not_to change { pipeline_item.reload.pipeline_stage_id }
        end
      end
    end

    context 'with custom_attribute_updated trigger' do
      let(:changed_attributes) { { 'custom_attributes' => [{}, { 'priority' => 'high' }] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'custom_attribute_updated', 'trigger_value' => '',
                        'action' => 'apply_label', 'action_value' => 'high-priority' }]
        })
      end

      it 'applies the label' do
        service.perform
        expect(conversation.reload.label_list).to include('high-priority')
      end
    end

    context 'with assign_agent action' do
      let(:changed_attributes) { { 'status' => ['open', 'resolved'] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'conversation_status_changed', 'trigger_value' => 'resolved',
                        'action' => 'assign_agent', 'action_value' => user.id }]
        })
      end

      it 'assigns the agent to the conversation' do
        service.perform
        expect(conversation.reload.assignee).to eq(user)
      end
    end

    context 'when stage has no automation rules' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      it 'does not raise an error' do
        expect { service.perform }.not_to raise_error
      end
    end

    context 'when conversation has no pipeline items' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      before { pipeline_item.destroy! }

      it 'does nothing without error' do
        expect { service.perform }.not_to raise_error
      end
    end

    context 'when target_stage_id belongs to a different pipeline' do
      let(:other_pipeline) { Pipeline.create!(name: 'Other Pipeline', pipeline_type: 'custom', created_by: user) }
      let(:other_stage) { PipelineStage.create!(pipeline: other_pipeline, name: 'Other Stage', position: 1) }
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'move_to_stage', 'action_value' => other_stage.id }]
        })
      end

      it 'does not move to a stage from a different pipeline' do
        expect { service.perform }.not_to change { pipeline_item.reload.pipeline_stage_id }
      end
    end

    context 'loop prevention via Current.executed_by' do
      let(:changed_attributes) { { 'label_list' => [[], ['x']] } }

      it 'sets Current.executed_by to :stage_automation during execution' do
        stage_a.update!(automation_rules: { 'rules' => [] })
        executed_by_value = nil
        allow_any_instance_of(described_class).to receive(:evaluate_stage_rules) do
          executed_by_value = Current.executed_by
        end
        service.perform
        expect(executed_by_value).to eq(:stage_automation)
      end

      it 'resets Current after execution' do
        stage_a.update!(automation_rules: { 'rules' => [] })
        service.perform
        expect(Current.executed_by).to be_nil
      end
    end

    # EVO-2201: an archived pipeline must stop acting on its own — its rules can message
    # the customer from a board the operator turned off and can no longer see.
    context 'when the pipeline is archived' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'move_to_stage', 'action_value' => stage_b.id }]
        })
      end

      it 'does not execute the rule' do
        pipeline.update!(is_active: false)

        expect { service.perform }.not_to change { pipeline_item.reload.pipeline_stage_id }
      end

      it 'logs the skip with the pipeline id and the reason' do
        pipeline.update!(is_active: false)
        allow(Rails.logger).to receive(:warn)

        service.perform

        expect(Rails.logger).to have_received(:warn).with(/#{pipeline.id} is archived/)
      end

      it 'still executes the rule while the pipeline is active' do
        expect { service.perform }.to change { pipeline_item.reload.pipeline_stage_id }.to(stage_b.id)
      end

      # A conversation may sit in several pipelines: one archived must not silence the rest.
      it 'evaluates the active pipeline of a conversation that also sits in an archived one' do
        pipeline.update!(is_active: false)

        live = Pipeline.create!(name: 'Live', pipeline_type: 'custom', created_by: user)
        live_a = PipelineStage.create!(pipeline: live, name: 'A', position: 1)
        live_b = PipelineStage.create!(pipeline: live, name: 'B', position: 2)
        live_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'move_to_stage', 'action_value' => live_b.id }]
        })
        live_item = PipelineItem.create!(pipeline: live, pipeline_stage: live_a, conversation: conversation)

        service.perform

        expect(live_item.reload.pipeline_stage_id).to eq(live_b.id)
        expect(pipeline_item.reload.pipeline_stage_id).to eq(stage_a.id)
      end
    end

    # Refusing the move keeps the conversation visible where it is, instead of pushing it
    # into a board nobody can see.
    context 'when move_to_pipeline targets an archived pipeline' do
      let(:changed_attributes) { { 'label_list' => [[], ['urgent']] } }
      let(:target) do
        t = Pipeline.create!(name: 'Target', pipeline_type: 'custom', created_by: user)
        PipelineStage.create!(pipeline: t, name: 'Inbox', position: 1)
        t
      end

      before do
        stage_a.update!(automation_rules: {
          'rules' => [{ 'trigger' => 'label_added', 'trigger_value' => 'urgent',
                        'action' => 'move_to_pipeline', 'action_value' => target.id }]
        })
      end

      # move_to_pipeline relocates the existing item rather than creating a second one.
      it 'refuses the move and says why' do
        target.update!(is_active: false)
        allow(Rails.logger).to receive(:warn)

        expect { service.perform }.not_to change { pipeline_item.reload.pipeline_id }
        expect(Rails.logger).to have_received(:warn).with(/#{target.id} is archived/)
      end

      it 'performs the move while the target is active' do
        expect { service.perform }.to change { pipeline_item.reload.pipeline_id }.to(target.id)
      end
    end
  end
end
