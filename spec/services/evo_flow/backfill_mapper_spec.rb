require 'rails_helper'

RSpec.describe EvoFlow::BackfillMapper do
  describe '.reporting_event_descriptor' do
    {
      'conversation_resolved' => ['conversation.resolved', 'conversation_management'],
      'first_response' => ['conversation.first_reply', 'reporting_management'],
      'reply_time' => ['conversation.reply_time', 'reporting_management'],
      'conversation_bot_handoff' => ['conversation.bot_handoff', 'reporting_management'],
      'conversation_bot_resolved' => ['conversation.bot_resolved', 'reporting_management']
    }.each do |legacy_name, (canonical, source)|
      it "maps #{legacy_name.inspect} to #{canonical.inspect} (source=#{source})" do
        reporting_event = instance_double(ReportingEvent, name: legacy_name)
        descriptor = described_class.reporting_event_descriptor(reporting_event)
        expect(descriptor[:event]).to eq(canonical)
        expect(descriptor[:source]).to eq(source)
      end
    end

    it 'raises EvoFlow::InvalidEventName for unmapped names (AC6 fail-loud)' do
      reporting_event = instance_double(ReportingEvent, name: 'unknown_legacy_event')
      expect { described_class.reporting_event_descriptor(reporting_event) }
        .to raise_error(EvoFlow::InvalidEventName)
    end

    it 'every canonical event is in EvoFlow::EVENT_NAMES (cross-check with enum)' do
      described_class::REPORTING_EVENTS.each_value do |descriptor|
        expect(EvoFlow::EVENT_NAMES).to include(descriptor[:event])
      end
    end
  end

  describe '.message_id_for' do
    it 'is deterministic for the same (source_type, source_id) pair' do
      first = described_class.message_id_for(:message, 42)
      expect(described_class.message_id_for(:message, 42)).to eq(first)
    end

    it 'namespaces by source_type so collisions across sources are impossible' do
      expect(described_class.message_id_for(:message, 1))
        .not_to eq(described_class.message_id_for(:reporting_event, 1))
    end

    it 'returns a SHA256 hex digest (64 chars)' do
      expect(described_class.message_id_for(:message, 1)).to match(/\A[0-9a-f]{64}\z/)
    end
  end
end
