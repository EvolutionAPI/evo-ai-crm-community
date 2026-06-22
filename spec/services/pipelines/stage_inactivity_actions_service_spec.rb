# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pipelines::StageInactivityActionsService do
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

  subject(:service) { described_class.new(pipeline_item.reload) }

  def set_rule(minutes:, base:, action: 'send_direct_message', action_value: 'Ainda por aqui?', id: SecureRandom.uuid, ai_message: nil)
    rule = {
      'id' => id, 'trigger' => 'inactivity',
      'trigger_value' => { 'minutes' => minutes, 'base' => base },
      'action' => action, 'action_value' => action_value
    }
    rule['ai_message'] = ai_message if ai_message
    stage_a.update!(automation_rules: { 'rules' => [rule] })
    rule
  end

  describe '#process' do
    context 'AC2 — stage_stagnation base, direct message' do
      before { set_rule(minutes: 30, base: 'stage_stagnation') }

      it 'does NOT fire before the threshold' do
        # entry movement just created → ~0 min in stage
        expect { service.process }.not_to change(StageInactivityExecution, :count)
      end

      it 'fires once after the threshold and records the execution' do
        pipeline_item.stage_movements.update_all(created_at: 31.minutes.ago)
        expect { service.process }.to change(StageInactivityExecution, :count).by(1)
      end
    end

    context 'AC13 — stagnation clock counts from current-stage entry, not entered_at' do
      before do
        set_rule(minutes: 30, base: 'stage_stagnation')
        # item has been in the pipeline for days, but just entered this stage
        pipeline_item.update_column(:entered_at, 3.days.ago)
        pipeline_item.stage_movements.update_all(created_at: 5.minutes.ago)
      end

      it 'does NOT fire (only 5 min in current stage)' do
        expect { service.process }.not_to change(StageInactivityExecution, :count)
      end
    end

    context 'AC1/AC3 — no_customer_reply base + idempotency' do
      before do
        set_rule(minutes: 5, base: 'no_customer_reply')
        Message.create!(account_id: nil, inbox: inbox, conversation: conversation, contact: contact,
                        message_type: :incoming, content: 'oi', created_at: 6.minutes.ago)
      rescue StandardError
        # account_id may be required differently in single-tenant; fall back
        conversation.messages.create!(inbox: inbox, message_type: :incoming, content: 'oi',
                                      created_at: 6.minutes.ago)
      end

      it 'fires once' do
        expect { service.process }.to change(StageInactivityExecution, :count).by(1)
      end

      it 'does not fire again on a second run (idempotent)' do
        service.process
        expect { described_class.new(pipeline_item.reload).process }
          .not_to change(StageInactivityExecution, :count)
      end
    end

    context 'AC13b — no_customer_reply on a lead with no conversation is a no-op' do
      let!(:lead_item) do
        PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage_a, contact: contact)
      end

      it 'skips (no conversation to measure)' do
        set_rule(minutes: 1, base: 'no_customer_reply')
        svc = described_class.new(lead_item.reload)
        expect { svc.process }.not_to change(StageInactivityExecution, :count)
      end
    end
  end

  describe 'reset semantics' do
    it 'AC5 — moving stages wipes stage_stagnation executions for the item' do
      StageInactivityExecution.create!(pipeline_item: pipeline_item, pipeline_stage_id: stage_a.id,
                                       rule_id: 'r1', base: 'stage_stagnation', action: 'send_direct_message',
                                       executed_at: Time.current)
      pipeline_item.move_to_stage(stage_b)
      expect(StageInactivityExecution.for_item(pipeline_item.id).where(base: 'stage_stagnation')).to be_empty
    end

    it 'base-specific reset does not cross-delete' do
      StageInactivityExecution.create!(pipeline_item: pipeline_item, pipeline_stage_id: stage_a.id,
                                       rule_id: 'reply1', base: 'no_customer_reply', action: 'send_direct_message',
                                       executed_at: Time.current)
      StageInactivityExecution.create!(pipeline_item: pipeline_item, pipeline_stage_id: stage_a.id,
                                       rule_id: 'stag1', base: 'stage_stagnation', action: 'send_direct_message',
                                       executed_at: Time.current)
      StageInactivityExecution.reset_for_item(pipeline_item.id, base: 'no_customer_reply')
      remaining = StageInactivityExecution.for_item(pipeline_item.id).pluck(:base)
      expect(remaining).to eq(['stage_stagnation'])
    end
  end
end
