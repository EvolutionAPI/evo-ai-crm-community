# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Message do
  include ActiveSupport::Testing::TimeHelpers

  describe '#refresh_conversation_activity!' do
    it 'uses current time when requested even if created_at is older' do
      conversation = double('Conversation', id: 'conv_1', class: Conversation)
      relation = double('Relation')
      message = described_class.new(created_at: 2.days.ago)
      allow(message).to receive(:conversation).and_return(conversation)

      travel_to(Time.zone.parse('2026-02-12 10:00:00')) do
        allow(Conversation).to receive(:where).with(id: 'conv_1').and_return(relation)
        expect(relation).to receive(:update_all).with(
          [
            'last_activity_at = GREATEST(COALESCE(last_activity_at, ?), ?), updated_at = ?',
            Time.current,
            Time.current,
            Time.current
          ]
        )

        message.refresh_conversation_activity!(message.created_at, use_current_time: true)
      end
    end

    it 'uses only provided timestamp when use_current_time is false' do
      older_time = Time.zone.parse('2026-02-10 10:00:00')
      conversation = double('Conversation', id: 'conv_2', class: Conversation)
      relation = double('Relation')
      message = described_class.new(created_at: older_time)
      allow(message).to receive(:conversation).and_return(conversation)

      travel_to(Time.zone.parse('2026-02-12 11:00:00')) do
        allow(Conversation).to receive(:where).with(id: 'conv_2').and_return(relation)
        expect(relation).to receive(:update_all).with(
          [
            'last_activity_at = GREATEST(COALESCE(last_activity_at, ?), ?), updated_at = ?',
            older_time,
            older_time,
            Time.current
          ]
        )

        message.refresh_conversation_activity!(message.created_at, use_current_time: false)
      end
    end
  end

  describe '#imported?' do
    let(:contact) { Contact.create!(name: 'Imported Spec Contact', email: "imported-#{SecureRandom.hex(4)}@example.com") }
    let(:inbox) { Inbox.create!(name: "Imported Spec Inbox #{SecureRandom.hex(2)}", channel: Channel::Api.create!) }
    let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
    let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

    it 'defaults to live' do
      message = described_class.new
      expect(message.source).to eq('live')
      expect(message.live?).to be(true)
      expect(message.imported?).to be(false)
    end

    it 'skips after_create_commit callbacks when imported' do
      message = described_class.new(
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'imported hello',
        source: :imported
      )

      expect(message).not_to receive(:execute_after_create_commit_callbacks)
      expect(message).not_to receive(:publish_message_created)
      expect(message).not_to receive(:sync_message_event)

      message.save!
    end

    it 'skips prevent_message_flooding when imported' do
      allow(Limits).to receive(:conversation_message_per_minute_limit).and_return(100)

      100.times do |i|
        described_class.create!(
          inbox: inbox,
          conversation: conversation,
          message_type: :incoming,
          content: "live-#{i}"
        )
      end

      live_attempt = described_class.new(
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'over-the-limit'
      )
      expect(live_attempt).not_to be_valid
      expect(live_attempt.errors[:base]).to include('Too many messages')

      imported = described_class.new(
        inbox: inbox,
        conversation: conversation,
        message_type: :incoming,
        content: 'imported-past-the-cap',
        source: :imported
      )
      expect(imported).to be_valid
    end
  end

  describe '#set_conversation_activity' do
    it 'delegates to refresh_conversation_activity! with current time' do
      conversation = double('Conversation', last_activity_at: nil)
      message = described_class.new(created_at: 1.day.ago)
      allow(message).to receive(:conversation).and_return(conversation)

      expect(message).to receive(:refresh_conversation_activity!).with(message.created_at, use_current_time: true)

      message.send(:set_conversation_activity)
    end
  end
end
