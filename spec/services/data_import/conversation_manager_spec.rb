# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataImport::ConversationManager do
  include ActiveSupport::Testing::TimeHelpers

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

  describe 'when a row fails mid-import' do
    let(:huge_content) { 'x' * 160_000 }

    it 'rolls back the conversation created in the same row' do
      attach_csv([
        header_row,
        "conv-tx-ok,#{contact.identifier},ok,incoming,2026-01-15T10:30:00Z,,text,m-ok",
        "conv-tx-bad,#{contact.identifier},#{huge_content},incoming,2026-01-15T10:31:00Z,,text,m-bad"
      ].join("\n"))

      expect { described_class.new(data_import).process }
        .to change { Conversation.where(identifier: %w[conv-tx-ok conv-tx-bad]).count }.by(1)

      expect(Conversation.find_by(identifier: 'conv-tx-bad')).to be_nil
      expect(Conversation.find_by(identifier: 'conv-tx-ok')).to be_present
    end

    it 'does NOT fire message_created listeners for imported messages' do
      attach_csv([
        header_row,
        "conv-listen,#{contact.identifier},hi,incoming,2026-01-15T10:30:00Z,,text,m-listen"
      ].join("\n"))

      expect(WebhookListener.instance).not_to receive(:message_created)
      expect(AutomationRuleListener.instance).not_to receive(:message_created)
      expect(ActionCableListener.instance).not_to receive(:message_created)
      expect(SendReplyJob).not_to receive(:perform_later)
      expect(AgentBots::SessionSyncService).not_to receive(:add_event_for_message)

      described_class.new(data_import).process
    end

    it 'does NOT bump conversation last_activity_at to current time' do
      attach_csv([
        header_row,
        "conv-activity,#{contact.identifier},hi,incoming,2026-01-15T10:30:00Z,,text,m-activity"
      ].join("\n"))

      expect_any_instance_of(Message).not_to receive(:set_conversation_activity)

      described_class.new(data_import).process
    end

    it 'does NOT increment prometheus counter' do
      attach_csv([
        header_row,
        "conv-prom,#{contact.identifier},hi,incoming,2026-01-15T10:30:00Z,,text,m-prom"
      ].join("\n"))

      expect(::Redis::Alfred).not_to receive(:incr)

      described_class.new(data_import).process
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

  describe 'imported conversation suppresses live callbacks (round 2 H1)' do
    before do
      attach_csv([
        header_row,
        "conv-h1,#{contact.identifier},hi,incoming,2026-01-15T10:30:00Z,,text,m-h1"
      ].join("\n"))
    end

    it 'marks the created conversation as Conversation.source = imported' do
      described_class.new(data_import).process
      expect(Conversation.find_by(identifier: 'conv-h1').source).to eq('imported')
    end

    it 'does NOT dispatch CONVERSATION_CREATED for imported conversations' do
      dispatched = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch) do |event, *_args|
        dispatched << event
      end

      described_class.new(data_import).process

      expect(dispatched).not_to include(Events::Types::CONVERSATION_CREATED)
    end

    it 'does NOT publish :conversation_created via Wisper for imported conversations' do
      published = []
      listener = ->(_payload) { published << :conversation_created }
      Wisper.subscribe(Object.new.tap { |o| o.define_singleton_method(:conversation_created, &listener) }) do
        described_class.new(data_import).process
      end

      expect(published).to be_empty
    end

    it 'does NOT assign imported conversation to any pipeline' do
      described_class.new(data_import).process
      conversation = Conversation.find_by(identifier: 'conv-h1')
      expect(conversation.pipeline_items).to be_empty
    end
  end

  describe '#parse_timestamp tolerance (round 2 sent_at)' do
    let(:manager) { described_class.new(data_import) }

    {
      '2026-01-15T10:30:00Z'      => Time.utc(2026, 1, 15, 10, 30, 0),
      '2026-01-15T10:30:00-03:00' => Time.utc(2026, 1, 15, 13, 30, 0),
      '2026-01-15 10:30:00'       => Time.utc(2026, 1, 15, 10, 30, 0),
      '2026-01-15'                => Time.utc(2026, 1, 15, 0, 0, 0),
      '1736937000'                => Time.at(1_736_937_000).utc,
      '1736937000000'             => Time.at(1_736_937_000).utc
    }.each do |input, expected|
      it "parses #{input.inspect} as UTC" do
        expect(manager.send(:parse_timestamp, input)).to eq(expected)
      end
    end

    it 'treats naive timestamps as UTC, not server-local' do
      Time.use_zone('America/Sao_Paulo') do
        parsed = manager.send(:parse_timestamp, '2026-01-15T10:30:00')
        expect(parsed.utc).to eq(Time.utc(2026, 1, 15, 10, 30, 0))
      end
    end

    it 'returns nil for unparseable values' do
      expect(manager.send(:parse_timestamp, 'not-a-date')).to be_nil
      expect(manager.send(:parse_timestamp, '')).to be_nil
      expect(manager.send(:parse_timestamp, nil)).to be_nil
    end
  end

  describe 'last_activity_at derived from sent_at (round 2 new low)' do
    it 'sets conversation.last_activity_at to the max sent_at across imported rows' do
      attach_csv([
        header_row,
        "conv-la,#{contact.identifier},old,incoming,2024-01-15T10:30:00Z,,text,la-1",
        "conv-la,#{contact.identifier},newer,outgoing,2024-03-20T11:45:00Z,Atendente,text,la-2",
        "conv-la,#{contact.identifier},newest,outgoing,2024-06-01T08:00:00Z,Atendente,text,la-3"
      ].join("\n"))

      described_class.new(data_import).process

      conversation = Conversation.find_by(identifier: 'conv-la')
      expect(conversation.last_activity_at.utc).to eq(Time.utc(2024, 6, 1, 8, 0, 0))
    end

    it 'does NOT bump last_activity_at past historical max via belongs_to touch' do
      attach_csv([
        header_row,
        "conv-touch,#{contact.identifier},hi,incoming,2024-01-01T00:00:00Z,,text,t-1"
      ].join("\n"))

      travel_to(Time.utc(2026, 6, 23, 18, 0, 0)) do
        described_class.new(data_import).process
      end

      conversation = Conversation.find_by(identifier: 'conv-touch')
      expect(conversation.last_activity_at.utc).to eq(Time.utc(2024, 1, 1, 0, 0, 0))
    end
  end
end
