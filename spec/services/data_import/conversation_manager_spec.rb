# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataImport::ConversationManager do
  let(:data_import) { DataImport.create!(data_type: 'conversations') }

  def attach_csv(content)
    data_import.import_file.attach(
      io: StringIO.new(content),
      filename: 'conversations.csv',
      content_type: 'text/csv'
    )
  end

  def header_row
    'conversation_external_id,contact_identifier,message_content,direction,sent_at,sender_name,message_type,message_external_id'
  end

  let!(:contact) { Contact.create!(name: 'Maria', identifier: "cust-#{SecureRandom.hex(4)}", phone_number: '+5511999998888') }

  describe '#process happy path' do
    before do
      attach_csv([
        header_row,
        "conv-1,#{contact.identifier},Oi tudo bem?,incoming,2026-01-15T10:30:00Z,,text,msg-1",
        "conv-1,#{contact.identifier},Tudo sim e voce?,outgoing,2026-01-15T10:31:00Z,Atendente,text,msg-2"
      ].join("\n"))
    end

    it 'creates a single Imported History inbox, conversation, and two messages' do
      manager = described_class.new(data_import)
      report = manager.process

      expect(report['total_rows']).to eq(2)
      expect(report['success_count']).to eq(2)
      expect(report['error_count']).to eq(0)

      conversation = Conversation.find_by(identifier: 'conv-1')
      expect(conversation).to be_present
      expect(conversation.inbox.display_name).to eq('Imported History')
      expect(conversation.inbox.channel_type).to eq('Channel::Api')
      expect(conversation.status).to eq('resolved')
      expect(conversation.messages.count).to eq(2)
      expect(conversation.messages.pluck(:message_type)).to match_array(%w[incoming outgoing])
    end

    it 'preserves sender_name in content_attributes when sender is unmapped (AC6)' do
      described_class.new(data_import).process

      outgoing = Conversation.find_by(identifier: 'conv-1').messages.find_by(message_type: 'outgoing')
      expect(outgoing.sender_id).to be_nil
      expect(outgoing.sender_type).to be_nil
      expect(outgoing.content_attributes['sender_name']).to eq('Atendente')
    end
  end

  describe 'contact lookup fallback' do
    it 'falls back to phone_number when identifier does not match' do
      attach_csv([header_row, 'conv-2,5511999998888,Hi,incoming,2026-01-15T10:30:00Z,,text,msg-a'].join("\n"))

      report = described_class.new(data_import).process

      expect(report['success_count']).to eq(1)
      expect(Conversation.find_by(identifier: 'conv-2').contact_id).to eq(contact.id)
    end
  end

  describe 'orphan contact (AC5)' do
    it 'fails the row and keeps processing' do
      attach_csv([
        header_row,
        'conv-3,does-not-exist,Hi,incoming,2026-01-15T10:30:00Z,,text,msg-x',
        "conv-3b,#{contact.identifier},Hello,outgoing,2026-01-15T10:31:00Z,,text,msg-y"
      ].join("\n"))

      report = described_class.new(data_import).process

      expect(report['total_rows']).to eq(2)
      expect(report['success_count']).to eq(1)
      expect(report['error_count']).to eq(1)
      expect(report['errors'].first['reason']).to include('contact not found')
      expect(report['errors'].first['row']).to eq(2)
    end
  end

  describe 'idempotent re-import (AC7)' do
    let(:rows) do
      [
        header_row,
        "conv-4,#{contact.identifier},First,incoming,2026-01-15T10:30:00Z,,text,msg-1"
      ]
    end

    it 'preserves conversation id and skips duplicate messages, adds new ones' do
      attach_csv(rows.join("\n"))
      described_class.new(data_import).process
      conversation = Conversation.find_by(identifier: 'conv-4')
      original_id = conversation.id

      second_import = DataImport.create!(data_type: 'conversations')
      second_import.import_file.attach(
        io: StringIO.new([
          header_row,
          "conv-4,#{contact.identifier},First,incoming,2026-01-15T10:30:00Z,,text,msg-1",
          "conv-4,#{contact.identifier},Second,outgoing,2026-01-15T10:31:00Z,,text,msg-2"
        ].join("\n")),
        filename: 'c.csv',
        content_type: 'text/csv'
      )

      described_class.new(second_import).process

      expect(Conversation.find_by(identifier: 'conv-4').id).to eq(original_id)
      expect(conversation.reload.messages.pluck(:source_id)).to match_array(%w[msg-1 msg-2])
    end
  end

  describe 'non-text message type (AC8)' do
    it 'replaces content with [mídia: {type}] without downloading' do
      attach_csv([
        header_row,
        "conv-5,#{contact.identifier},http://example.com/file.jpg,incoming,2026-01-15T10:30:00Z,,image,msg-img"
      ].join("\n"))

      described_class.new(data_import).process

      msg = Conversation.find_by(identifier: 'conv-5').messages.first
      expect(msg.content).to eq('[mídia: image]')
      expect(msg.content_attributes['imported_media_type']).to eq('image')
    end
  end

  describe 'malformed row (AC11)' do
    it 'records error for invalid direction and continues' do
      attach_csv([
        header_row,
        "conv-6,#{contact.identifier},Hi,sideways,2026-01-15T10:30:00Z,,text,msg-bad",
        "conv-7,#{contact.identifier},OK,incoming,2026-01-15T10:31:00Z,,text,msg-ok"
      ].join("\n"))

      report = described_class.new(data_import).process

      expect(report['error_count']).to eq(1)
      expect(report['success_count']).to eq(1)
      expect(report['errors'].first['reason']).to include('invalid direction')
    end

    it 'rejects missing required header upfront' do
      attach_csv("conversation_external_id,contact_identifier,message_content,direction\nconv-x,1,Hi,incoming")

      expect { described_class.new(data_import).process }.to raise_error(CSV::MalformedCSVError, /missing required columns/)
    end

    it 'recovers from ActiveRecord::RecordInvalid raised by a single bad row (M1)' do
      huge_content = 'x' * 160_000
      attach_csv([
        header_row,
        "conv-m1a,#{contact.identifier},#{huge_content},incoming,2026-01-15T10:30:00Z,,text,m-huge",
        "conv-m1b,#{contact.identifier},ok,outgoing,2026-01-15T10:31:00Z,,text,m-ok"
      ].join("\n"))

      report = described_class.new(data_import).process

      expect(report['error_count']).to eq(1)
      expect(report['success_count']).to eq(1)
      expect(report['errors'].first['reason']).to match(/validation failed/i)
    end
  end
end
