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
