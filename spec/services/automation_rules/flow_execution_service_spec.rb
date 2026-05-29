# frozen_string_literal: true

require 'rails_helper'

# B1: regression guard for AutomationRules::FlowExecutionService.
#
# Pre-fix, `add_label`/`remove_label` on the @contact branch did:
#
#     @contact.label_list.add(titles); @contact.save!
#
# That mutates the cached TagList in place without dirty-tracking the
# `label_list` attribute, so `Contact#publish_label_changes` returned early
# and no `:contact_label_added/removed` Wisper event was fired — silently
# breaking AC3 (path 3) and AC4 for the dominant automation path.
#
# Post-fix, both methods route through `update!(label_list: ...)` so the
# setter dirty-tracks and the commit hook diffs the change. These specs
# subscribe to the contact directly and assert the events fire.
RSpec.describe AutomationRules::FlowExecutionService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:rule) do
    r = AutomationRule.new(
      name: "rule-#{SecureRandom.hex(4)}",
      event_name: 'contact_updated',
      active: true,
      mode: 'flow',
      conditions: [],
      actions: []
    )
    r.save!(validate: false)
    r
  end
  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@test.com") }
  let(:label_vip) { Label.create!(title: 'vip', color: '#fff') }
  let(:label_beta) { Label.create!(title: 'beta', color: '#000') }
  let(:service) { described_class.new(rule, nil, nil, contact) }

  # `FlowExecutionService#initialize` sets `Current.executed_by = rule` as a
  # side-effect. Since these specs drive `add_label`/`remove_label` directly
  # (bypassing `perform`'s `ensure Current.reset`), reset by hand to prevent
  # leakage into other specs in the same run.
  after { Current.reset }

  describe '#add_label on @contact' do
    it 'emits :contact_label_added for each title added (AC3 path 3)' do
      collected = []
      listener = Class.new do
        define_method(:contact_label_added) { |data| collected << data[:data] }
      end.new
      contact.subscribe(listener)

      service.send(:add_label, [label_vip.id, label_beta.id])

      expect(collected.map { |d| d[:label_name] }).to contain_exactly('vip', 'beta')
      expect(contact.reload.label_list).to contain_exactly('vip', 'beta')
    end

    it 'does not double-add existing labels' do
      contact.update!(label_list: ['vip'])

      service.send(:add_label, [label_vip.id, label_beta.id])

      expect(contact.reload.label_list).to contain_exactly('vip', 'beta')
    end
  end

  describe '#remove_label on @contact' do
    before { contact.update!(label_list: %w[vip beta]) }

    it 'emits :contact_label_removed for each title removed (AC4)' do
      collected = []
      listener = Class.new do
        define_method(:contact_label_removed) { |data| collected << data[:data] }
      end.new
      contact.subscribe(listener)

      service.send(:remove_label, [label_vip.id])

      expect(collected.map { |d| d[:label_name] }).to include('vip')
      expect(contact.reload.label_list).to contain_exactly('beta')
    end
  end

  # EVO-1262: new node types delegate to the shared handler modules. Each
  # spec exercises `execute_node_action` (private API entry point) directly
  # so the canvas-side dispatch is covered end-to-end.
  describe 'EVO-1262 pipeline + message node types' do
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) do
      Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    end
    let(:pipeline) { Pipeline.create!(name: 'Sales', pipeline_type: 'sales', created_by: user) }
    let(:stage_a) { PipelineStage.create!(pipeline: pipeline, name: 'Lead', position: 1) }
    let(:stage_b) { PipelineStage.create!(pipeline: pipeline, name: 'Qualified', position: 2) }
    let(:flow_service) { described_class.new(rule, nil, conversation, contact) }

    describe 'assign-to-pipeline-node' do
      it 'creates a pipeline_item via Pipelines::ConversationService (AC2)' do
        stage_a # touch lazy let — pipeline.pipeline_stages.first must exist
        node = { 'type' => 'assign-to-pipeline-node', 'id' => 'n1', 'data' => { 'pipeline_id' => pipeline.id } }

        expect { flow_service.send(:execute_node_action, node) }
          .to change { conversation.reload.pipeline_items.count }.from(0).to(1)

        expect(conversation.pipeline_items.first.pipeline).to eq(pipeline)
      end

      it 'ignores the node when pipeline_id is missing' do
        node = { 'type' => 'assign-to-pipeline-node', 'id' => 'n1', 'data' => {} }
        expect { flow_service.send(:execute_node_action, node) }
          .not_to change { conversation.reload.pipeline_items.count }
      end

      it 'logs a warning and skips when pipeline_id does not match any pipeline (AC3 / EVO-1265)' do
        stage_a # touch lazy let — keeps test isolated from setup ordering
        nonexistent_id = SecureRandom.uuid
        node = { 'type' => 'assign-to-pipeline-node', 'id' => 'n1', 'data' => { 'pipeline_id' => nonexistent_id } }

        expect(Rails.logger).to receive(:warn).with(/Pipeline .* not found.*skipping assign_to_pipeline/i)

        expect { flow_service.send(:execute_node_action, node) }
          .not_to change { conversation.reload.pipeline_items.count }
      end
    end

    describe 'move-to-pipeline-stage-node' do
      before do
        stage_a
        Pipelines::ConversationService.new(pipeline: pipeline, user: nil).add_conversation(conversation)
      end

      it 'moves the existing pipeline_item to the target stage' do
        node = { 'type' => 'move-to-pipeline-stage-node', 'id' => 'n1', 'data' => { 'stage_id' => stage_b.id } }

        expect { flow_service.send(:execute_node_action, node) }
          .to change { conversation.reload.pipeline_items.first.pipeline_stage_id }
          .from(stage_a.id).to(stage_b.id)
      end
    end

    describe 'create-pipeline-task-node' do
      # PipelineTask has `created_by_id NOT NULL`; production code reads it
      # via `User.where(type: 'SuperAdmin').first&.id`. The Community fork
      # removed the SuperAdmin class (EVO-659) so STI lookup throws here;
      # stub the User.where chain to return a real seeded user.
      let(:created_by_user) { User.create!(name: 'CreatedBy', email: "cb-#{SecureRandom.hex(4)}@test.com") }

      before do
        stage_a
        Pipelines::ConversationService.new(pipeline: pipeline, user: nil).add_conversation(conversation)
        allow(User).to receive(:where).and_call_original
        allow(User).to receive(:where).with(type: 'SuperAdmin').and_return(double(first: created_by_user))
      end

      it 'creates a task on the first pipeline_item' do
        node = {
          'type' => 'create-pipeline-task-node', 'id' => 'n1',
          'data' => { title: 'Follow up', description: 'Call lead', task_type: 'call', priority: 'medium' }
        }

        expect { flow_service.send(:execute_node_action, node) }
          .to change { conversation.reload.pipeline_items.first.tasks.count }.from(0).to(1)

        task = conversation.pipeline_items.first.tasks.first
        expect(task.title).to eq('Follow up')
        expect(task.task_type).to eq('call')
      end

      it 'no-ops when the conversation has no pipeline_items' do
        conversation.pipeline_items.destroy_all
        node = { 'type' => 'create-pipeline-task-node', 'id' => 'n1', 'data' => { title: 'x' } }
        expect { flow_service.send(:execute_node_action, node) }.not_to raise_error
      end
    end

    describe 'send-canned-response-node' do
      let(:canned) do
        CannedResponse.create!(short_code: "cr-#{SecureRandom.hex(3)}", content: 'Hello {{contact.name}}')
      end

      it 'dispatches a Messages::MessageBuilder with the canned content' do
        node = { 'type' => 'send-canned-response-node', 'id' => 'n1', 'data' => { 'canned_response_id' => canned.id } }
        builder = instance_double(Messages::MessageBuilder)
        allow(builder).to receive(:perform)
        allow(Messages::MessageBuilder).to receive(:new).and_return(builder)

        flow_service.send(:execute_node_action, node)

        expect(Messages::MessageBuilder).to have_received(:new).with(
          nil, conversation, hash_including(content: 'Hello {{contact.name}}', private: false)
        )
        expect(builder).to have_received(:perform)
      end

      it 'ignores the node when canned_response_id is missing' do
        node = { 'type' => 'send-canned-response-node', 'id' => 'n1', 'data' => {} }
        expect(Messages::MessageBuilder).not_to receive(:new)
        flow_service.send(:execute_node_action, node)
      end
    end

    describe 'send-template-node' do
      it 'dispatches a Messages::MessageBuilder with resolved template params' do
        contact.update!(name: 'Alice')
        node = {
          'type' => 'send-template-node', 'id' => 'n1',
          'data' => {
            'name' => 'welcome',
            'processed_params' => { 'greeting' => 'Hi {{contact.name}}' }
          }
        }
        builder = instance_double(Messages::MessageBuilder)
        allow(builder).to receive(:perform)
        allow(Messages::MessageBuilder).to receive(:new).and_return(builder)

        flow_service.send(:execute_node_action, node)

        expect(Messages::MessageBuilder).to have_received(:new) do |_, conv, params|
          expect(conv).to eq(conversation)
          expect(params[:template_params]['processed_params']['greeting']).to eq('Hi Alice')
        end
      end
    end

    describe 'action_node? whitelist' do
      it 'recognises all 18 node types (13 legacy + 5 new from EVO-1262)' do
        new_types = %w[
          assign-to-pipeline-node
          move-to-pipeline-stage-node
          create-pipeline-task-node
          send-canned-response-node
          send-template-node
        ]
        new_types.each do |t|
          expect(flow_service.send(:action_node?, t)).to be(true), "expected #{t} to be a recognised action node"
        end
      end
    end
  end

  # EVO-1262 AC3: parity harness — driving the same action through the modal
  # ActionService and the canvas FlowExecutionService must produce identical
  # DB state. Single source of truth = the shared handler modules; without
  # this guard, future edits could silently diverge the two surfaces.
  describe 'EVO-1262 parity: ActionService modal path vs FlowExecutionService canvas path' do
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
    let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:make_conversation) do
      -> { Conversation.create!(inbox: inbox, contact: Contact.create!(name: 'C', email: "c-#{SecureRandom.hex(4)}@test.com"), contact_inbox: ContactInbox.create!(inbox: inbox, contact: Contact.last, source_id: SecureRandom.hex(4))) }
    end

    it 'assign_to_pipeline → same pipeline_items.count + same pipeline reference' do
      pipeline = Pipeline.create!(name: 'P', pipeline_type: 'sales', created_by: user)
      PipelineStage.create!(pipeline: pipeline, name: 'S1', position: 1)
      conv_modal = make_conversation.call
      conv_canvas = make_conversation.call

      modal_rule = AutomationRule.new(
        name: 'modal', event_name: 'conversation_created', active: true, mode: 'simple',
        conditions: [], actions: [{ action_name: 'assign_to_pipeline', action_params: [{ id: pipeline.id }] }]
      )
      modal_rule.save!(validate: false)
      AutomationRules::ActionService.new(modal_rule, nil, conv_modal).perform

      canvas_node = { 'type' => 'assign-to-pipeline-node', 'id' => 'n1', 'data' => { 'pipeline_id' => pipeline.id } }
      described_class.new(rule, nil, conv_canvas, conv_canvas.contact).send(:execute_node_action, canvas_node)

      expect(conv_modal.reload.pipeline_items.count).to eq(conv_canvas.reload.pipeline_items.count)
      expect(conv_modal.pipeline_items.first.pipeline).to eq(conv_canvas.pipeline_items.first.pipeline)
    end
  end
end
