require 'rails_helper'

RSpec.describe EvoFlow::PayloadBuilder do
  let(:occurred_at) { Time.zone.parse('2026-05-19T12:00:00Z') }

  describe '.build_track (real TrackEventDto)' do
    subject(:payload) do
      described_class.build_track(
        event_name: 'contact.created',
        contact_id: 42,
        properties: { a: 1 },
        occurred_at: occurred_at,
        message_id: 'sha'
      )
    end

    it 'matches the real evo-flow track DTO (AC5)' do
      expect(payload).to eq(
        messageId: 'sha',
        contactId: '42',
        event: 'contact.created',
        properties: { a: 1 },
        timestamp: occurred_at.utc.iso8601
      )
    end

    it 'has no accountId and no eventType keys (single-tenant, AC5)' do
      expect(payload).not_to have_key(:accountId)
      expect(payload).not_to have_key(:eventType)
      expect(payload).not_to have_key(:eventName)
    end

    it 'stringifies contactId and defaults nil properties to {}' do
      built = described_class.build_track(
        event_name: 'contact.created', contact_id: 7,
        properties: nil, occurred_at: occurred_at, message_id: 'x'
      )
      expect(built[:contactId]).to eq('7')
      expect(built[:properties]).to eq({})
    end

    context 'when event_name is not in EvoFlow::EVENT_NAMES' do
      it 'raises EvoFlow::InvalidEventName with the unknown name (AC1)' do
        expect do
          described_class.build_track(
            event_name: 'nao_existe', contact_id: 1, properties: {},
            occurred_at: occurred_at, message_id: 'x'
          )
        end.to raise_error(EvoFlow::InvalidEventName, /Unknown EvoFlow event_name: "nao_existe"/)
      end

      it 'renders nil as `nil` (not empty) in the error message' do
        expect do
          described_class.build_track(
            event_name: nil, contact_id: 1, properties: {},
            occurred_at: occurred_at, message_id: 'x'
          )
        end.to raise_error(EvoFlow::InvalidEventName, /Unknown EvoFlow event_name: nil/)
      end
    end
  end

  describe '.build_identify (real IdentifyEventDto)' do
    subject(:payload) do
      described_class.build_identify(
        event_name: 'contact.updated',
        contact_id: 42,
        traits: { email: 'x' },
        occurred_at: occurred_at,
        message_id: 'sha'
      )
    end

    it 'matches the real evo-flow identify DTO (AC5b)' do
      expect(payload).to eq(
        messageId: 'sha',
        contactId: '42',
        eventName: 'contact.updated',
        traits: { email: 'x' },
        timestamp: occurred_at.utc.iso8601
      )
    end

    it 'has no accountId/eventType and no track-only `event` key (AC5b)' do
      expect(payload).not_to have_key(:accountId)
      expect(payload).not_to have_key(:eventType)
      expect(payload).not_to have_key(:event)
    end

    context 'when event_name is not in EvoFlow::EVENT_NAMES' do
      it 'raises EvoFlow::InvalidEventName with the unknown name (AC2b)' do
        expect do
          described_class.build_identify(
            event_name: 'tambem_nao', contact_id: 1, traits: {},
            occurred_at: occurred_at, message_id: 'x'
          )
        end.to raise_error(EvoFlow::InvalidEventName, /Unknown EvoFlow event_name: "tambem_nao"/)
      end
    end
  end

  describe '.message_id_for' do
    it 'is deterministic and equals SHA256(event|contact|uuid) (AC3)' do
      first = described_class.message_id_for('message.delivered', 42, 'abc')
      second = described_class.message_id_for('message.delivered', 42, 'abc')

      expect(first).to eq(second)
      expect(first).to eq(Digest::SHA256.hexdigest('message.delivered|42|abc'))
    end

    it 'differs when any component differs' do
      base = described_class.message_id_for('message.delivered', 42, 'abc')
      expect(described_class.message_id_for('message.read', 42, 'abc')).not_to eq(base)
      expect(described_class.message_id_for('message.delivered', 43, 'abc')).not_to eq(base)
      expect(described_class.message_id_for('message.delivered', 42, 'xyz')).not_to eq(base)
    end
  end

  describe '.iso8601' do
    it 'normalises a valid string to UTC ISO-8601' do
      expect(described_class.iso8601('2026-05-19T09:00:00-03:00')).to eq('2026-05-19T12:00:00Z')
      expect(described_class.iso8601('2026-05-19T12:00:00Z')).to eq('2026-05-19T12:00:00Z')
    end

    it 'fails fast on an unparseable string (no silent bad data) (F11)' do
      expect { described_class.iso8601('not-a-timestamp') }.to raise_error(ArgumentError)
    end

    it 'formats Time as UTC' do
      expect(described_class.iso8601(occurred_at)).to eq(occurred_at.utc.iso8601)
    end

    it 'raises ArgumentError on nil — no implicit Time.current fallback (L3)' do
      expect { described_class.iso8601(nil) }
        .to raise_error(ArgumentError, /occurred_at is required/)
    end
  end

  # AC6: event_name must be inside EvoFlow::EVENT_NAMES; otherwise the
  # builder raises EvoFlow::InvalidEventName. Caught in CI, not prod —
  # listeners rescue StandardError and tag enqueue-loss.
  describe 'event_name validation (AC6)' do
    it 'accepts canonical event_names from EvoFlow::EVENT_NAMES' do
      EvoFlow::EVENT_NAMES.each do |name|
        expect do
          described_class.build_track(
            event_name: name, contact_id: 1, properties: {},
            occurred_at: occurred_at, message_id: 'x'
          )
        end.not_to raise_error
      end
    end

    it 'raises EvoFlow::InvalidEventName for build_track with an unknown event_name' do
      expect do
        described_class.build_track(
          event_name: 'not.a.real.event', contact_id: 1, properties: {},
          occurred_at: occurred_at, message_id: 'x'
        )
      end.to raise_error(EvoFlow::InvalidEventName, /not\.a\.real\.event/)
    end

    it 'raises EvoFlow::InvalidEventName for build_identify with an unknown event_name' do
      expect do
        described_class.build_identify(
          event_name: 'contact.exploded', contact_id: 1, traits: {},
          occurred_at: occurred_at, message_id: 'x'
        )
      end.to raise_error(EvoFlow::InvalidEventName)
    end
  end
end
