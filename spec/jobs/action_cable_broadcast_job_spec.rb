# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionCableBroadcastJob, type: :job do
  describe '#perform' do
    it 'broadcasts event data to each member token' do
      tokens = %w[token-a token-b]
      data = { id: 1, content: 'hello' }

      tokens.each do |token|
        expect(ActionCable.server).to receive(:broadcast).with(
          token,
          hash_including(event: 'message.created', data: hash_including(:content))
        )
      end

      described_class.perform_now(tokens, 'message.created', data)
    end

    it 'does nothing when members is blank' do
      expect(ActionCable.server).not_to receive(:broadcast)

      described_class.perform_now([], 'message.created', {})
    end

    it 'fetches fresh conversation data for conversation update events' do
      contact = Contact.create!(name: 'BC', email: "bc-#{SecureRandom.hex(4)}@test.com")
      channel = Channel::WebWidget.create!(website_url: 'https://bc.example.com')
      inbox = Inbox.create!(name: 'BC Inbox', channel: channel)
      contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: "bc-#{SecureRandom.hex(4)}")
      conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      expect(ActionCable.server).to receive(:broadcast).with(
        'token-x',
        hash_including(event: 'conversation.status_changed', data: hash_including(:id))
      )

      described_class.perform_now(
        ['token-x'],
        'conversation.status_changed',
        { id: conversation.id }
      )
    end
  end

  # EVO-1551 round 4 — worker-shape regression.
  # Previous rounds set Current.account in the spec's `before` block, which
  # masks the actual production state: this job runs on a Sidekiq thread
  # where EvoAuthConcern never executed, so Current.account is nil. The
  # masker used to fail-open in that path and the broadcast carried raw
  # PII. The fix is the RuntimeConfig.account fallback in
  # `ContactPiiMasker.account_flag_enabled?`.
  describe '#prepare_broadcast_data — masks PII when running on a thread without Current.account (round 4)' do
    before { Current.reset }
    after  { Current.reset }

    let(:phone_contact) do
      Contact.create!(name: '5511999998888', phone_number: '+5511999998888', email: "leak-#{SecureRandom.hex(4)}@test.com")
    end
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://w4.example.com') }
    let(:inbox) { Inbox.create!(name: 'W4 Inbox', channel: channel) }
    let(:phone_contact_inbox) do
      ContactInbox.create!(inbox: inbox, contact: phone_contact, source_id: '5511999998888@s.whatsapp.net')
    end
    let(:phone_conversation) do
      Conversation.create!(inbox: inbox, contact: phone_contact, contact_inbox: phone_contact_inbox)
    end

    ActionCableBroadcastJob::CONVERSATION_UPDATE_EVENTS.each do |event_name|
      it "masks contact_inbox.source_id for #{event_name} with Current.account = nil" do
        allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => true } })

        captured = nil
        allow(ActionCable.server).to receive(:broadcast) do |_token, payload|
          captured = payload
        end

        described_class.perform_now(['token-1'], event_name, { id: phone_conversation.id })

        source_id = captured.dig(:data, :contact_inbox, 'source_id') ||
                    captured.dig(:data, :contact_inbox, :source_id)
        expect(source_id).not_to include('5511999998888')
        expect(source_id).to end_with('@s.whatsapp.net')
      end
    end

    it 'does NOT mask when the flag is off in RuntimeConfig (avoid over-masking)' do
      allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => false } })

      captured = nil
      allow(ActionCable.server).to receive(:broadcast) do |_token, payload|
        captured = payload
      end

      described_class.perform_now(['token-1'], Events::Types::CONVERSATION_UPDATED, { id: phone_conversation.id })

      # When the flag is off, `EventDataPresenter#push_contact_inbox` returns the
      # raw ContactInbox AR record (not a Hash), so source_id is read directly.
      contact_inbox = captured.dig(:data, :contact_inbox)
      source_id = contact_inbox.respond_to?(:source_id) ? contact_inbox.source_id : contact_inbox['source_id']
      expect(source_id).to eq('5511999998888@s.whatsapp.net')
    end
  end
end
