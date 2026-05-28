require 'rails_helper'

RSpec.describe EvoFlow::SchemaValidator do
  describe '.validate!' do
    context 'when the event name is not in the schema (unknown / future)' do
      it 'passes through silently to preserve forward-compat' do
        expect do
          described_class.validate!('not.a.real.event', {})
        end.not_to raise_error
      end
    end

    context 'when the event is "custom"' do
      it 'accepts any free-form payload (AC4)' do
        expect do
          described_class.validate!('custom', { anything: 1, deeply: 'whatever' })
        end.not_to raise_error
      end

      it 'accepts an empty payload' do
        expect { described_class.validate!('custom', {}) }.not_to raise_error
      end
    end

    context 'AC3 — required-field enforcement (track event)' do
      it 'raises InvalidEventPayload when message.delivered is missing message_id' do
        expect do
          described_class.validate!(
            'message.delivered',
            channel_type: 'Channel::Whatsapp',
            conversation_id: '550e8400-e29b-41d4-a716-446655440001',
            source: 'messaging'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload) do |err|
          expect(err.event_name).to eq('message.delivered')
          expect(err.field).to eq('message_id')
          expect(err.reason).to eq(:missing_required)
        end
      end

      it 'accepts message.delivered when all required fields are present' do
        expect do
          described_class.validate!(
            'message.delivered',
            message_id: '550e8400-e29b-41d4-a716-446655440000',
            channel_type: 'Channel::Whatsapp',
            conversation_id: '550e8400-e29b-41d4-a716-446655440001',
            source: 'messaging'
          )
        end.not_to raise_error
      end

      it 'tolerates string keys (Sidekiq round-trips through JSON)' do
        expect do
          described_class.validate!(
            'message.delivered',
            'message_id' => '550e8400-e29b-41d4-a716-446655440000',
            'channel_type' => 'Channel::Whatsapp',
            'conversation_id' => '550e8400-e29b-41d4-a716-446655440001',
            'source' => 'messaging'
          )
        end.not_to raise_error
      end
    end

    context 'AC3 — required-field enforcement (identify event)' do
      it 'raises InvalidEventPayload when contact.created traits lack id' do
        expect do
          described_class.validate!('contact.created', source: 'contact_created')
        end.to raise_error(EvoFlow::InvalidEventPayload) do |err|
          expect(err.field).to eq('id')
        end
      end

      it 'accepts contact.created when id and source are present' do
        expect do
          described_class.validate!('contact.created', id: '550e8400-e29b-41d4-a716-446655440000', source: 'contact_created')
        end.not_to raise_error
      end
    end

    context 'H1: empty string is treated as missing for string-like required fields' do
      it 'raises MissingRequiredField when message_id is empty string' do
        expect do
          described_class.validate!(
            'message.delivered',
            message_id: '',
            channel_type: 'Channel::Whatsapp',
            conversation_id: '550e8400-e29b-41d4-a716-446655440002',
            source: 'messaging'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload) do |err|
          expect(err.field).to eq('message_id')
          expect(err.reason).to eq(:missing_required)
        end
      end

      it 'accepts false/0 for boolean/number fields (not treated as missing)' do
        expect do
          described_class.validate!(
            'campaign.triggered',
            pipeline_item_id: '550e8400-e29b-41d4-a716-446655440000', pipeline_id: '550e8400-e29b-41d4-a716-446655440001', source: 's',
            is_lead: false, assigned_by_id: 0
          )
        end.not_to raise_error
      end
    end

    context 'M1: :uuid type strictness' do
      it 'rejects arbitrary non-UUID non-numeric strings' do
        expect do
          described_class.validate!(
            'message.delivered',
            message_id: 'not-a-uuid', channel_type: 'Channel::Whatsapp',
            conversation_id: 'also-not-a-uuid', source: 's'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload)
      end

      it 'accepts canonical UUID strings' do
        expect do
          described_class.validate!(
            'message.delivered',
            message_id: '550e8400-e29b-41d4-a716-446655440000',
            channel_type: 'Channel::Whatsapp',
            conversation_id: '550e8400-e29b-41d4-a716-446655440001',
            source: 's'
          )
        end.not_to raise_error
      end

      it 'accepts numeric strings (legacy contact_id paths emit "42")' do
        expect do
          described_class.validate!(
            'message.delivered',
            message_id: '42', channel_type: 'Channel::Whatsapp',
            conversation_id: '99', source: 's'
          )
        end.not_to raise_error
      end
    end

    # L4: invariant — custom MUST always accept any payload.
    context 'L4: custom sentinel invariant (AC4)' do
      it 'has empty required and empty optional schemas' do
        schema = EvoFlow::EventSchema.fetch('custom')
        expect(schema[:required]).to eq({})
        expect(schema[:optional]).to eq({})
      end
    end

    # F4: deep-freeze invariant — defends against runtime mutation of the
    # schema by production code.
    context 'F4: schema is deep-frozen' do
      it 'freezes the outer DEFINITIONS hash' do
        expect(EvoFlow::EventSchema::DEFINITIONS).to be_frozen
      end

      it 'freezes per-event entry hashes' do
        expect(EvoFlow::EventSchema::DEFINITIONS['message.delivered']).to be_frozen
      end

      it 'freezes nested required/optional hashes' do
        entry = EvoFlow::EventSchema::DEFINITIONS['message.delivered']
        expect(entry[:required]).to be_frozen
        expect(entry[:optional]).to be_frozen
      end
    end

    context 'type validation' do
      it 'rejects boolean where uuid is expected' do
        expect do
          described_class.validate!(
            'message.delivered',
            message_id: true,
            channel_type: 'Channel::Whatsapp',
            conversation_id: '550e8400-e29b-41d4-a716-446655440001',
            source: 'messaging'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload) do |err|
          expect(err.field).to eq('message_id')
          expect(err.reason).to eq(:invalid_type)
        end
      end

      it 'accepts numeric uuid values from legacy contact_id paths' do
        expect do
          described_class.validate!(
            'message.created',
            message_id: 42,
            channel_type: 'Channel::Whatsapp',
            conversation_id: '550e8400-e29b-41d4-a716-446655440001',
            source: 'messaging',
            message_type: 'incoming'
          )
        end.not_to raise_error
      end

      it 'accepts ISO-8601 strings for date fields' do
        expect do
          described_class.validate!(
            'contact.deleted',
            source: 'contact_deleted',
            deleted_at: '2026-05-25T12:00:00Z'
          )
        end.not_to raise_error
      end

      it 'accepts Time/ActiveSupport::TimeWithZone for date fields' do
        expect do
          described_class.validate!(
            'contact.deleted',
            source: 'contact_deleted',
            deleted_at: Time.zone.parse('2026-05-25T12:00:00Z')
          )
        end.not_to raise_error
      end

      it 'rejects an unparseable string for a date field' do
        expect do
          described_class.validate!(
            'contact.deleted',
            source: 'contact_deleted',
            deleted_at: 'not-a-date'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload)
      end

      it 'rejects an arbitrary string where uuid is expected' do
        expect do
          described_class.validate!(
            'conversation.created',
            conversation_id: '550e8400-e29b-41d4-a716-446655440001',
            inbox_id: 'seven',
            source: 'conversation_management'
          )
        end.to raise_error(EvoFlow::InvalidEventPayload)
      end
    end

    context 'optional fields' do
      it 'allows the field to be absent' do
        expect do
          described_class.validate!(
            'conversation.created',
            conversation_id: '550e8400-e29b-41d4-a716-446655440001',
            inbox_id: '550e8400-e29b-41d4-a716-446655440002',
            source: 'conversation_management'
          )
        end.not_to raise_error
      end

      it 'still type-checks the field when present' do
        expect do
          described_class.validate!(
            'conversation.created',
            conversation_id: '550e8400-e29b-41d4-a716-446655440001',
            inbox_id: '550e8400-e29b-41d4-a716-446655440002',
            source: 'conversation_management',
            channel_type: 12345
          )
        end.to raise_error(EvoFlow::InvalidEventPayload)
      end
    end
  end
end
