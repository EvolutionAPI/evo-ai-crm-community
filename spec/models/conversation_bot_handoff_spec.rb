# frozen_string_literal: true

require 'rails_helper'

# EVO-1560 — the AI→human handoff must leave a durable, renderable timeline
# item. bot_handoff! previously only dispatched an event; it now also persists
# an activity message (reusing the existing activity-message mechanism).
RSpec.describe 'Conversation#bot_handoff! activity', type: :model do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) do
    conv = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    # Bypass the callback that auto-opens new conversations to set up a real
    # pending -> open handoff transition.
    conv.update_column(:status, Conversation.statuses[:pending]) # rubocop:disable Rails/SkipsModelValidations
    conv.reload
  end

  def captured_activity_params
    captured = []
    allow(Conversations::ActivityMessageJob).to receive(:perform_later) do |_record, params|
      captured << params
    end
    captured
  end

  it 'persists a bot-handoff activity message tagged bot_to_human' do
    params = captured_activity_params

    conversation.bot_handoff!

    handoff = params.find { |p| p.dig(:content_attributes, :handoff_type) == 'bot_to_human' }
    expect(handoff).to be_present
    expect(handoff[:message_type]).to eq(:activity)
    expect(handoff[:content]).to eq(I18n.t('conversations.activity.bot_handoff'))
  end

  it 'does not log a handoff activity when the conversation is already open' do
    open_conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open)
    params = captured_activity_params

    open_conversation.bot_handoff!

    expect(params.any? { |p| p.dig(:content_attributes, :handoff_type) == 'bot_to_human' }).to be(false)
  end

  it 'opens the conversation' do
    captured_activity_params

    conversation.bot_handoff!

    expect(conversation.reload).to be_open
  end

  it 'persists a valid activity Message row with the handoff metadata' do
    params = conversation.send(:activity_message_params, I18n.t('conversations.activity.bot_handoff'))
                         .merge(content_attributes: { handoff_type: 'bot_to_human' })

    expect { conversation.messages.create!(params) }.to change(conversation.messages, :count).by(1)

    msg = conversation.messages.last
    expect(msg.message_type).to eq('activity')
    expect(msg.content).to eq(I18n.t('conversations.activity.bot_handoff'))
    expect(msg.content_attributes['handoff_type']).to eq('bot_to_human')
  end

  it 'localizes the handoff content in en and pt-BR' do
    expect(I18n.t('conversations.activity.bot_handoff', locale: :en))
      .to eq('The bot handed off the conversation to an agent')
    expect(I18n.t('conversations.activity.bot_handoff', locale: :pt_BR))
      .to eq('O bot encaminhou a conversa para um atendente')
  end
end

# EVO-1680 — the reverse human→bot handoff persists a symmetrical activity
# message and re-engages the bot by moving the conversation back to pending.
RSpec.describe 'Conversation#return_to_bot!', type: :model do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test-rb.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox RB', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact RB', email: "rb-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:human_user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com", password: 'Password123!') }
  let(:open_conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox, status: :open, assignee: human_user)
  end

  def stub_active_bot(value)
    allow_any_instance_of(Inbox).to receive(:active_bot?).and_return(value)
  end

  def captured_activity_params
    captured = []
    allow(Conversations::ActivityMessageJob).to receive(:perform_later) do |_record, params|
      captured << params
    end
    captured
  end

  context 'when inbox has an active agent bot and conversation is open' do
    before { stub_active_bot(true) }

    it 'moves status from open to pending and clears assignee' do
      captured_activity_params

      expect { open_conversation.return_to_bot! }
        .to change { open_conversation.reload.status }.from('open').to('pending')
        .and change { open_conversation.reload.assignee_id }.from(human_user.id).to(nil)
    end

    it 'persists a handoff activity message tagged human_to_bot' do
      params = captured_activity_params

      open_conversation.return_to_bot!

      handoff = params.find { |p| p.dig(:content_attributes, :handoff_type) == 'human_to_bot' }
      expect(handoff).to be_present
      expect(handoff[:message_type]).to eq(:activity)
      expect(handoff[:content]).to eq(I18n.t('conversations.activity.human_handoff'))
    end

    it 'dispatches CONVERSATION_HUMAN_HANDOFF exactly once' do
      captured_activity_params
      expect(open_conversation).to receive(:dispatcher_dispatch).with(Events::Types::CONVERSATION_HUMAN_HANDOFF).once

      open_conversation.return_to_bot!
    end
  end

  context 'when inbox has no active agent bot' do
    before { stub_active_bot(false) }

    it 'raises Conversations::InvalidHandoffError without changing state' do
      expect(Conversations::ActivityMessageJob).not_to receive(:perform_later)

      expect { open_conversation.return_to_bot! }
        .to raise_error(Conversations::InvalidHandoffError, 'inbox has no agent bot connected')
        .and not_change { open_conversation.reload.status }
        .and not_change { open_conversation.reload.assignee_id }
    end
  end

  context 'when conversation status is not open' do
    before { stub_active_bot(true) }

    %i[pending resolved snoozed].each do |bad_status|
      it "raises Conversations::InvalidHandoffError for status=#{bad_status} without enqueuing activity" do
        open_conversation.update_column(:status, Conversation.statuses[bad_status]) # rubocop:disable Rails/SkipsModelValidations

        expect(Conversations::ActivityMessageJob).not_to receive(:perform_later)
        expect { open_conversation.return_to_bot! }
          .to raise_error(Conversations::InvalidHandoffError, 'conversation must be open')
      end
    end
  end

  it 'localizes the human_handoff content in all 6 supported locales' do
    expect(I18n.t('conversations.activity.human_handoff', locale: :en))
      .to eq('The agent handed the conversation back to the bot')
    expect(I18n.t('conversations.activity.human_handoff', locale: :pt))
      .to eq('O atendente devolveu a conversa ao bot')
    expect(I18n.t('conversations.activity.human_handoff', locale: :pt_BR))
      .to eq('O atendente devolveu a conversa ao bot')
    expect(I18n.t('conversations.activity.human_handoff', locale: :es))
      .to eq('El agente devolvió la conversación al bot')
    expect(I18n.t('conversations.activity.human_handoff', locale: :fr))
      .to eq("L'agent a renvoyé la conversation au bot")
    expect(I18n.t('conversations.activity.human_handoff', locale: :it))
      .to eq("L'agente ha restituito la conversazione al bot")
  end
end
