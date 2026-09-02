# frozen_string_literal: true

require 'rails_helper'

# Critical coverage for F1 (the adversarial-review blocker): media attachments
# MUST exist at the moment the Message commits, so Message#send_reply takes the
# `attachments.present? -> SendReplyJob.set(wait: 5.seconds)` branch instead of
# dispatching immediately with text only. If attachments were created AFTER the
# message commit, the channel would already have sent text-only and the media
# would be lost.
RSpec.describe AgentBots::RemoteMediaAttacher do
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  # A small in-memory file standing in for Down.download's return value.
  def fake_download(content_type: 'video/mp4', filename: 'VLS_Atleta.mp4')
    io = StringIO.new('fake-bytes')
    io.define_singleton_method(:content_type) { content_type }
    io.define_singleton_method(:original_filename) { filename }
    io
  end

  describe '.build_attachments (atomicity / F1)' do
    it 'builds the attachment on the message BEFORE save, so it persists in the same commit' do
      allow(Down).to receive(:download).and_return(fake_download)

      message = Message.new(
        inbox: inbox, conversation: conversation, message_type: 'outgoing', content: 'Assiste aí'
      )
      described_class.build_attachments(message, [{ url: 'https://x.com/v.mp4', file_type: 'video' }])

      # Attachment exists in memory before persistence
      expect(message.attachments.size).to eq(1)
      expect(message.attachments.first.file_type).to eq('video')

      message.save!
      message.reload
      # And persisted in the same commit with the blob attached
      expect(message.attachments.count).to eq(1)
      expect(message.attachments.first.file).to be_attached
    end

    it 'skips a download failure without dropping the message or other media (AC11)' do
      call = 0
      allow(Down).to receive(:download) do
        call += 1
        raise Down::Error, 'boom' if call == 1

        fake_download(content_type: 'image/jpeg', filename: 'pic.jpg')
      end

      message = Message.new(inbox: inbox, conversation: conversation, message_type: 'outgoing', content: 'x')
      described_class.build_attachments(message, [
                                          { url: 'https://x.com/bad.mp4', file_type: 'video' },
                                          { url: 'https://x.com/pic.jpg', file_type: 'image' }
                                        ])
      message.save!
      # only the good one survived
      expect(message.reload.attachments.pluck(:file_type)).to eq(['image'])
    end

    it 'rejects SSRF targets (link-local metadata endpoint) without downloading (AC14)' do
      expect(Down).not_to receive(:download)
      message = Message.new(inbox: inbox, conversation: conversation, message_type: 'outgoing', content: 'x')
      described_class.build_attachments(message, [{ url: 'http://169.254.169.254/latest/meta-data', file_type: 'image' }])
      expect(message.attachments).to be_empty
    end

    it 'drops invalid file_type without raising (AC16)' do
      message = Message.new(inbox: inbox, conversation: conversation, message_type: 'outgoing', content: 'x')
      expect do
        described_class.build_attachments(message, [{ url: 'https://x.com/v.mp4', file_type: 'bogus' }])
      end.not_to raise_error
      expect(message.attachments).to be_empty
    end
  end

  describe 'Message#send_reply branch (F1 end-to-end intent)' do
    it 'schedules SendReplyJob with a delay when the committed message has attachments' do
      allow(Down).to receive(:download).and_return(fake_download)
      delayed = false
      allow(SendReplyJob).to receive(:set).and_wrap_original do |orig, *args|
        delayed = true
        orig.call(*args)
      end
      allow(SendReplyJob).to receive(:perform_later)

      message = Message.new(inbox: inbox, conversation: conversation, message_type: 'outgoing', content: 'Assiste aí')
      described_class.build_attachments(message, [{ url: 'https://x.com/v.mp4', file_type: 'video' }])
      message.save! # triggers after_create_commit -> send_reply

      expect(delayed).to be(true), 'expected SendReplyJob.set(wait:) — media present at commit'
    end
  end
end
