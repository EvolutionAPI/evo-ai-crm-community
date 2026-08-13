# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Macros::ExecutionService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:macro) do
    Macro.create!(
      name: 'Test macro',
      created_by: user,
      updated_by: user,
      actions: [{ 'action_name' => 'send_webhook_event', 'action_params' => ['https://webhook.site/abc'] }]
    )
  end

  describe '#send_webhook_event' do
    let(:service) { described_class.new(macro, conversation, user) }
    let(:execution) { MacroExecution.create!(macro: macro, conversation: conversation, user: user, status: :pending) }

    before { service.instance_variable_set(:@execution, execution) }

    it 'enqueues WebhookJob with stripped URL, payload, :macro_webhook and the execution id' do
      expect(WebhookJob).to receive(:perform_later).with(
        'https://webhook.site/abc',
        hash_including(event: 'macro.executed'),
        :macro_webhook,
        execution.id
      )

      service.send(:send_webhook_event, ["  https://webhook.site/abc  \t"])
    end

    it 'skips enqueue and warns when the URL is blank' do
      expect(WebhookJob).not_to receive(:perform_later)
      expect(Rails.logger).to receive(:warn).with(/skipping send_webhook_event/)

      service.send(:send_webhook_event, ['   '])
    end

    it 'skips enqueue when params is nil' do
      expect(WebhookJob).not_to receive(:perform_later)
      service.send(:send_webhook_event, nil)
    end
  end

  describe '#perform' do
    let(:service) { described_class.new(macro, conversation, user) }

    before do
      allow(WebhookJob).to receive(:perform_later)
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
    end

    context 'with a webhook action' do
      it 'creates a MacroExecution and leaves it pending while WebhookJob runs async' do
        execution = service.perform

        expect(execution).to be_persisted
        expect(execution.status).to eq('pending')
        expect(execution.actions_result.first['status']).to eq('enqueued')
      end

      it 'does not dispatch the completion event when work is still pending' do
        expect(Rails.configuration.dispatcher).not_to receive(:dispatch)
          .with(Events::Types::MACRO_EXECUTION_COMPLETED, anything, anything)

        service.perform
      end
    end

    context 'with a synchronous action that fails' do
      let(:macro) do
        Macro.create!(
          name: 'Test macro',
          created_by: user,
          updated_by: user,
          actions: [{ 'action_name' => 'send_message', 'action_params' => ['hello'] }]
        )
      end

      before do
        allow(service).to receive(:send_message).and_raise(StandardError, 'boom')
      end

      it 'marks execution as failed and dispatches completion event' do
        expect(Rails.configuration.dispatcher).to receive(:dispatch).with(
          Events::Types::MACRO_EXECUTION_COMPLETED,
          anything,
          hash_including(:macro_execution)
        )

        expect { service.perform }.not_to raise_error
        execution = MacroExecution.last
        expect(execution.status).to eq('failed')
        expect(execution.actions_result.first['status']).to eq('failed')
      end
    end
  end

  # CRM-54: an unresolvable action param used to end in a green toast. For
  # assign_team / assign_agent the shared handler returns silently; for
  # add_label / remove_label it is worse — a non-uuid is treated as a label
  # title and a junk label is created on the conversation. Both paths must end
  # as `failed`, and the validation must live here, never in the shared handler.
  describe 'unresolvable action params' do
    let(:service) { described_class.new(macro, conversation, user) }

    before { allow(Rails.configuration.dispatcher).to receive(:dispatch) }

    def macro_with(action_name, action_params)
      Macro.create!(
        name: "macro-#{SecureRandom.hex(4)}",
        created_by: user,
        updated_by: user,
        actions: [{ 'action_name' => action_name, 'action_params' => action_params }]
      )
    end

    def failed_result(action_name, action_params)
      execution = described_class.new(macro_with(action_name, action_params), conversation, user).perform

      expect(execution.status).to eq('failed')
      result = execution.actions_result.first
      expect(result['action']).to eq(action_name)
      expect(result['status']).to eq('failed')
      result
    end

    describe '#assign_team' do
      it 'fails the action when the team does not exist' do
        result = failed_result('assign_team', [SecureRandom.uuid])

        expect(result['error']).to match(/assign_team.*not found/)
        expect(conversation.reload.team_id).to be_nil
      end

      it 'fails the action when the id was truncated to a number' do
        failed_result('assign_team', [8])

        expect(conversation.reload.team_id).to be_nil
      end

      it 'assigns the team and reports success for a real team id' do
        team = Team.create!(name: "team-#{SecureRandom.hex(4)}")
        execution = described_class.new(macro_with('assign_team', [team.id]), conversation, user).perform

        expect(execution.status).to eq('success')
        expect(execution.actions_result.first['status']).to eq('success')
        expect(conversation.reload.team_id).to eq(team.id)
      end

      it 'still unassigns the team when the param is the explicit unassign value' do
        team = Team.create!(name: "team-#{SecureRandom.hex(4)}")
        conversation.update!(team_id: team.id)

        execution = described_class.new(macro_with('assign_team', ['nil']), conversation, user).perform

        expect(execution.status).to eq('success')
        expect(conversation.reload.team_id).to be_nil
      end
    end

    describe '#assign_agent' do
      it 'fails the action when the agent does not exist' do
        result = failed_result('assign_agent', [SecureRandom.uuid])

        expect(result['error']).to match(/assign_agent.*not found/)
        expect(conversation.reload.assignee_id).to be_nil
      end

      it 'fails the action when the agent is not a member of the inbox' do
        outsider = User.create!(name: 'Outsider', email: "outsider-#{SecureRandom.hex(4)}@test.com")

        result = failed_result('assign_agent', [outsider.id])

        expect(result['error']).to match(/not a member of inbox/)
        expect(conversation.reload.assignee_id).to be_nil
      end

      it 'assigns the agent and reports success when they belong to the inbox' do
        InboxMember.create!(inbox: inbox, user: user)

        execution = described_class.new(macro_with('assign_agent', [user.id]), conversation, user).perform

        expect(execution.status).to eq('success')
        expect(conversation.reload.assignee_id).to eq(user.id)
      end
    end

    describe '#add_label' do
      it 'fails the action and tags nothing when the value is not a uuid' do
        result = failed_result('add_label', ['8'])

        expect(result['error']).to match(/add_label.*is not a label id/)
        expect(conversation.reload.label_list).to be_empty
      end

      it 'does not report a bad param to the exception tracker' do
        expect(EvolutionExceptionTracker).not_to receive(:new)

        failed_result('add_label', ['8'])
      end

      it 'fails the action when the label uuid does not exist' do
        result = failed_result('add_label', [SecureRandom.uuid])

        expect(result['error']).to match(/add_label.*not found/)
        expect(conversation.reload.label_list).to be_empty
      end

      it 'applies a registered label and reports success' do
        label = Label.create!(title: "urgente-#{SecureRandom.hex(4)}")

        execution = described_class.new(macro_with('add_label', [label.id]), conversation, user).perform

        expect(execution.status).to eq('success')
        expect(conversation.reload.label_list).to include(label.title)
      end
    end

    describe '#remove_label' do
      it 'fails the action when the value is not a uuid' do
        result = failed_result('remove_label', ['8'])

        expect(result['error']).to match(/remove_label.*is not a label id/)
      end

      it 'removes a registered label and reports success' do
        label = Label.create!(title: "vip-#{SecureRandom.hex(4)}")
        conversation.update!(label_list: [label.title])

        execution = described_class.new(macro_with('remove_label', [label.id]), conversation, user).perform

        expect(execution.status).to eq('success')
        expect(conversation.reload.label_list).not_to include(label.title)
      end
    end

    # The frontend used to save `parseInt(uuid) || uuid`, which truncated every
    # uuid starting with a hex digit 1-9. Ids starting with 0 or a letter passed
    # by accident. All 16 must round-trip through an execution unchanged.
    describe 'ids across the whole first-hex-digit range' do
      %w[0 1 2 3 4 5 6 7 8 9 a b c d e f].each do |first_digit|
        it "resolves a team whose uuid starts with #{first_digit}" do
          team = Team.create!(
            id: "#{first_digit}#{SecureRandom.uuid[1..]}",
            name: "team-#{first_digit}-#{SecureRandom.hex(4)}"
          )

          execution = described_class.new(macro_with('assign_team', [team.id]), conversation, user).perform

          expect(execution.status).to eq('success')
          expect(conversation.reload.team_id).to eq(team.id)
        end
      end
    end
  end

  # Guard-rail: the uuid-only rule is scoped to macros. Journeys, automation
  # rules and pipelines legitimately apply labels by NAME through
  # resolve_label_titles (EVO-1932) and must keep working.
  describe 'title passthrough of the shared handler (non-regression)' do
    let(:rule) do
      automation_rule = AutomationRule.new(
        name: "rule-#{SecureRandom.hex(4)}",
        event_name: 'conversation_updated',
        active: true,
        mode: 'simple',
        conditions: [],
        actions: [{ 'action_name' => 'add_label', 'action_params' => ['promocao'] }]
      )
      automation_rule.save!(validate: false)
      automation_rule
    end

    it 'still applies a label by title from an automation rule' do
      AutomationRules::ActionService.new(rule, nil, conversation).perform

      expect(conversation.reload.label_list).to include('promocao')
    end
  end

  describe '#send_message with a template (EVO-1235)' do
    let(:template) { MessageTemplate.create!(name: 'macro_tpl', content: 'Hi {{first_name}}', channel: nil) }
    let(:service) { described_class.new(macro, conversation, user) }

    it 'renders the template content when the action arg carries a template id' do
      service.send(:send_message, [{ 'message_template_id' => template.id, 'processed_params' => { 'first_name' => 'Ada' } }])

      message = conversation.messages.where(message_type: 'outgoing').last
      expect(message.content).to eq('Hi Ada')
    end

    it 'still sends plain inline content when the arg is a string' do
      service.send(:send_message, ['just text'])

      message = conversation.messages.where(message_type: 'outgoing').last
      expect(message.content).to eq('just text')
    end
  end
end
