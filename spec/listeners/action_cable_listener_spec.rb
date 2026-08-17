# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionCableListener do
  let(:listener) { described_class.instance }
  let(:user) do
    User.create!(name: 'Agent', email: "listener-#{SecureRandom.hex(4)}@test.com")
  end
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://listener.example.com') }
  let(:inbox) do
    ib = Inbox.create!(name: 'Listener Inbox', channel: channel)
    InboxMember.create!(inbox: ib, user: user)
    ib
  end
  let(:contact) { Contact.create!(name: 'LC', email: "lc-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: "lc-#{SecureRandom.hex(4)}") }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:message) do
    Message.create!(
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'Test message'
    )
  end

  EventData = Struct.new(:data)

  describe '#message_created' do
    it 'enqueues broadcast via perform_later for MESSAGE_CREATED' do
      event = EventData.new({ message: message })

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        anything,
        Events::Types::MESSAGE_CREATED,
        anything
      )

      listener.message_created(event)
    end
  end

  describe '#conversation_created' do
    it 'enqueues broadcast via perform_later for CONVERSATION_CREATED' do
      event = EventData.new({ conversation: conversation })

      expect(ActionCableBroadcastJob).to receive(:perform_later).with(
        anything,
        Events::Types::CONVERSATION_CREATED,
        anything
      )

      listener.conversation_created(event)
    end
  end

  describe 'broadcast routing' do
    it 'skips broadcast when tokens are blank' do
      expect(ActionCableBroadcastJob).not_to receive(:perform_later)

      listener.send(:broadcast, nil, [], Events::Types::MESSAGE_CREATED, { id: 1 })
    end
  end

  # EVO-1551 round 2 — CB-2 regression.
  # ActionCable listeners triggered by inbound WhatsApp messages run with
  # `Current.user = nil`. Before the fix, ContactPiiMasker.should_mask?
  # bailed out in that path and the websocket frame carried raw phone /
  # identifier values — exactly the leak the card promises to close.
  describe '#message_created — PII masking when Current.user is nil (CB-2)' do
    before do
      Current.reset
      Current.account = { 'settings' => { 'mask_contact_pii' => true } }
    end

    after { Current.reset }

    let(:phone_contact) do
      Contact.create!(
        name: '5511999998888',
        phone_number: '+5511999998888',
        email: "leak-#{SecureRandom.hex(4)}@test.com"
      )
    end
    let(:phone_contact_inbox) do
      ContactInbox.create!(inbox: inbox, contact: phone_contact, source_id: '5511999998888@s.whatsapp.net')
    end
    let(:phone_conversation) do
      Conversation.create!(inbox: inbox, contact: phone_contact, contact_inbox: phone_contact_inbox)
    end
    let(:inbound_message) do
      Message.create!(
        inbox: inbox,
        conversation: phone_conversation,
        message_type: :incoming,
        content: 'oi',
        sender: phone_contact
      )
    end

    it 'masks contact PII in the enqueued payload' do
      payload = nil
      allow(ActionCableBroadcastJob).to receive(:perform_later) do |_tokens, _event, data|
        payload = data
      end

      listener.message_created(EventData.new({ message: inbound_message }))

      expect(payload).not_to be_nil
      expect(payload.dig(:conversation, :contact_inbox, :source_id)).not_to include('5511999998888')
      expect(payload.dig(:conversation, :contact_inbox, :source_id)).to end_with('@s.whatsapp.net')
      expect(payload[:sender]).to be_a(Hash)
      expect(payload.dig(:sender, :phone_number)).not_to include('99999-8888'.delete('-'))
      expect(payload.dig(:sender, :phone_number)).to match(/\*/)
      expect(payload.dig(:sender, :email)).to match(/\A.\*+@/)
    end
  end

  # EVO-1551 round 3 — CB-3 regression.
  # `contact_created/updated/merged/deleted` broadcast to the account-wide
  # topic, which every agent on the account is subscribed to. The listener
  # runs synchronously in the request context, so when an admin edits a
  # contact `Current.user = admin` and the previous code skipped masking —
  # leaking raw PII to every agent listening on the account socket.
  describe 'contact_* broadcasts force-mask for account audience (CB-3)' do
    before do
      Current.reset
      Current.account = { 'settings' => { 'mask_contact_pii' => true } }
      Current.user = instance_double('User', administrator?: true, name: 'Admin', push_event_data: { id: 1, name: 'Admin', type: 'user' })
    end

    after { Current.reset }

    let(:phone_contact) do
      Contact.create!(
        name: '5511999998888',
        phone_number: '+5511999998888',
        identifier: '5511999998888@s.whatsapp.net',
        email: "leak-#{SecureRandom.hex(4)}@test.com"
      )
    end

    %i[contact_created contact_updated contact_merged contact_deleted].each do |listener_method|
      it "masks PII on #{listener_method} even when triggered by an admin" do
        payload = nil
        allow(ActionCableBroadcastJob).to receive(:perform_later) do |_tokens, _event, data|
          payload = data
        end

        listener.public_send(listener_method, EventData.new({ contact: phone_contact }))

        expect(payload).not_to be_nil
        expect(payload[:phone_number]).to match(/\*/)
        expect(payload[:phone_number]).not_to include('99999998888')
        expect(payload[:email]).to match(/\A.\*+@/)
        expect(payload[:identifier]).not_to include('5511999998888')
        expect(payload[:identifier]).to end_with('@s.whatsapp.net')
        expect(payload[:name]).to match(/\*/)
      end
    end
  end

  # EVO-1551 round 3 — CB-4 regression.
  # `Conversations::EventDataPresenter#push_data` previously assigned the raw
  # `ContactInbox` ActiveRecord model, whose `as_json` dump exposed the raw
  # `source_id` (the WhatsApp JID embeds the phone number). The fix masks
  # `source_id` whenever the account flag is on, regardless of `Current.user`.
  describe '#conversation_created — masks contact_inbox.source_id (CB-4)' do
    before do
      Current.reset
      Current.account = { 'settings' => { 'mask_contact_pii' => true } }
      Current.user = instance_double('User', administrator?: true, name: 'Admin', push_event_data: { id: 1, name: 'Admin', type: 'user' })
    end

    after { Current.reset }

    let(:phone_contact) do
      Contact.create!(name: '5511999998888', phone_number: '+5511999998888')
    end
    let(:phone_contact_inbox) do
      ContactInbox.create!(inbox: inbox, contact: phone_contact, source_id: '5511999998888@s.whatsapp.net')
    end
    let(:phone_conversation) do
      Conversation.create!(inbox: inbox, contact: phone_contact, contact_inbox: phone_contact_inbox)
    end

    it 'masks source_id in the CONVERSATION_CREATED payload even when an admin is the actor' do
      payload = nil
      allow(ActionCableBroadcastJob).to receive(:perform_later) do |_tokens, _event, data|
        payload = data
      end

      listener.conversation_created(EventData.new({ conversation: phone_conversation }))

      expect(payload).not_to be_nil
      source_id = payload.dig(:contact_inbox, 'source_id') || payload.dig(:contact_inbox, :source_id)
      expect(source_id).not_to include('5511999998888')
      expect(source_id).to end_with('@s.whatsapp.net')
    end
  end
end
