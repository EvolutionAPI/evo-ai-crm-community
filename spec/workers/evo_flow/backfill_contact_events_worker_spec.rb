require 'rails_helper'
require 'webmock/rspec'

# Heavy use of AR relation doubles: this fork has no factories for
# Message/Conversation/ReportingEvent, and existing model specs follow the
# same `double(...)`/`instance_double(...)` style (see spec/models/message_spec.rb).
RSpec.describe EvoFlow::BackfillContactEventsWorker, type: :worker do
  let(:client) { instance_double(EvoFlow::Client) }
  let(:fake_alfred) { {} }

  before do
    allow(EvoFlow::Client).to receive(:new).and_return(client)
    allow(client).to receive(:post_batch).and_return({})

    # Stub Redis::Alfred in-memory: get/set/incr/delete persist to a hash.
    allow(Redis::Alfred).to receive(:get) { |k| fake_alfred[k] }
    allow(Redis::Alfred).to receive(:set) { |k, v, **_| fake_alfred[k] = v.to_s }
    allow(Redis::Alfred).to receive(:incr) { |k| fake_alfred[k] = (fake_alfred[k].to_i + 1).to_s }
    allow(Redis::Alfred).to receive(:delete) { |k| fake_alfred.delete(k) }

    # EvoFlow.enabled? is checked at the top of perform — keep it true unless a
    # specific test flips it.
    allow(EvoFlow).to receive(:enabled?).and_return(true)
  end

  def uuid(suffix)
    format('%<a>08x-%<b>04x-%<c>04x-%<d>04x-%<e>012x', a: suffix, b: 0, c: 0, d: 0, e: suffix)
  end

  def build_relation_stub(model_constant, records)
    relation = instance_double(ActiveRecord::Relation, table_name: "#{model_constant}Relation")
    %i[where order joins].each do |chain|
      allow(relation).to receive(chain).and_return(relation)
    end
    allow(relation).to receive(:find_each) do |**opts, &block|
      start_at = opts[:start]
      filtered = start_at ? records.select { |r| r.id > start_at } : records
      filtered.each { |r| block.call(r) }
    end
    allow(model_constant).to receive(:where).and_return(relation)
    relation
  end

  def stub_message_relation(records)
    build_relation_stub(Message, records)
  end

  def stub_reporting_event_relation(records)
    build_relation_stub(ReportingEvent, records)
  end

  def build_conversation(contact_id: uuid(1))
    instance_double(Conversation, id: uuid(100), contact_id: contact_id)
  end

  def build_message(id:, content: 'msg body', conversation: build_conversation, created_at: Time.zone.parse('2026-01-01T00:00:00Z'))
    instance_double(
      Message,
      id: id, content: content, conversation: conversation,
      conversation_id: conversation&.id,
      sender_type: 'Contact', sender_id: conversation&.contact_id,
      created_at: created_at
    )
  end

  def build_reporting_event(id:, name: 'conversation_resolved', conversation: build_conversation,
                            event_start_time: Time.zone.parse('2026-01-01T00:00:00Z'))
    instance_double(
      ReportingEvent,
      id: id, name: name, conversation: conversation,
      conversation_id: conversation&.id,
      user_id: uuid(2), value: 1.0, value_in_business_hours: 1.0,
      event_start_time: event_start_time
    )
  end

  describe 'sidekiq configuration' do
    it 'uses the integrations queue with retry: 2' do
      expect(described_class.sidekiq_options['queue']).to eq(:integrations)
      expect(described_class.sidekiq_options['retry']).to eq(2)
    end
  end

  describe 'integration feature gate (M1)' do
    it 'short-circuits when EvoFlow.enabled? is false (DRY_RUN=true)' do
      allow(EvoFlow).to receive(:enabled?).and_return(false)
      stub_message_relation([build_message(id: uuid(10))])
      stub_reporting_event_relation([])
      allow(Rails.logger).to receive(:warn)

      described_class.new.perform(nil, 'dry_run' => true)

      expect(client).not_to have_received(:post_batch)
      expect(Rails.logger).to have_received(:warn).with(/integration is disabled/)
    end

    # H1 (2nd review): when DRY_RUN=false and integration disabled, the
    # enabled? gate must fire BEFORE Client.new — otherwise the worker
    # raises ConfigurationError and emits a misleading :evo_flow_backfill_dropped
    # broadcast for what is really a feature-flag state.
    it 'short-circuits BEFORE instantiating Client when DRY_RUN=false and disabled' do
      allow(EvoFlow).to receive(:enabled?).and_return(false)
      stub_message_relation([])
      stub_reporting_event_relation([])
      allow(Rails.logger).to receive(:warn)

      described_class.new.perform(nil, 'dry_run' => false)

      expect(EvoFlow::Client).not_to have_received(:new)
      expect(Rails.logger).to have_received(:warn).with(/integration is disabled/)
    end
  end

  describe 'dry_run (AC1)' do
    it 'does not POST to evo-flow and does not write to the live cursor' do
      stub_message_relation([build_message(id: uuid(10))])
      stub_reporting_event_relation([])

      described_class.new.perform(nil, 'dry_run' => true)

      expect(client).not_to have_received(:post_batch)
      expect(fake_alfred.keys.grep(/^backfill:cursor:/)).to be_empty
    end

    it 'logs would_backfill summary and one sample_payload line per source (M2)' do
      stub_message_relation([build_message(id: uuid(10)), build_message(id: uuid(11))])
      stub_reporting_event_relation([build_reporting_event(id: uuid(20))])
      logged = []
      allow(Rails.logger).to receive(:info) { |m| logged << m }

      described_class.new.perform(nil, 'dry_run' => true)

      expect(logged.grep(/would_backfill .*type=message count=2/)).not_to be_empty
      expect(logged.grep(/would_backfill .*type=reporting_event count=1/)).not_to be_empty
      # One sample per source — Message + ReportingEvent (2 total).
      expect(logged.grep(/sample_payload source=message/).size).to eq(1)
      expect(logged.grep(/sample_payload source=reporting_event/).size).to eq(1)
    end
  end

  describe 'publish path (AC2)' do
    it 'POSTs one batch via Client#post_batch with the built payloads' do
      messages = Array.new(2) { |i| build_message(id: uuid(i + 10)) }
      stub_message_relation(messages)
      stub_reporting_event_relation([])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(client).to have_received(:post_batch) do |events|
        expect(events.size).to eq(2)
        expect(events.first[:event]).to eq('conversation.activity')
        expect(events.first[:contactId]).to eq(uuid(1))
        expect(events.first[:messageId]).to match(/\A[0-9a-f]{64}\z/)
      end
    end

    it 'increments the processed counter per payload' do
      stub_message_relation(Array.new(3) { |i| build_message(id: uuid(i + 10)) })
      stub_reporting_event_relation([])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(fake_alfred['evo_flow_backfill:processed:message']).to eq('3')
    end
  end

  describe 'ReportingEvent mapping (AC4)' do
    {
      'conversation_resolved' => 'conversation.resolved',
      'first_response' => 'conversation.first_reply',
      'reply_time' => 'conversation.reply_time',
      'conversation_bot_handoff' => 'conversation.bot_handoff',
      'conversation_bot_resolved' => 'conversation.bot_resolved'
    }.each do |legacy, canonical|
      it "maps #{legacy.inspect} -> #{canonical.inspect} in the emitted payload" do
        stub_message_relation([])
        stub_reporting_event_relation([build_reporting_event(id: uuid(20), name: legacy)])

        described_class.new.perform(nil, 'dry_run' => false)

        expect(client).to have_received(:post_batch) do |events|
          expect(events.first[:event]).to eq(canonical)
        end
      end
    end
  end

  describe 'cursor resumibility with UUID primary keys (AC5, H1)' do
    it 'passes a string cursor to find_each(start:) and clears it on completion' do
      records = [build_message(id: uuid(10)), build_message(id: uuid(11))]
      relation = stub_message_relation(records)
      stub_reporting_event_relation([])
      cursor_value = uuid(5)
      window = (1.year.ago).utc.strftime('%Y-%m-%d')
      fake_alfred["backfill:cursor:#{window}:message"] = cursor_value

      described_class.new.perform(nil, 'dry_run' => false)

      expect(relation).to have_received(:find_each)
        .with(hash_including(start: cursor_value, batch_size: 1000))
      expect(fake_alfred["backfill:cursor:#{window}:message"]).to be_nil
    end

    it 'omits the start: arg when no cursor is set' do
      relation = stub_message_relation([build_message(id: uuid(10))])
      stub_reporting_event_relation([])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(relation).to have_received(:find_each) do |**opts|
        expect(opts).not_to include(:start)
        expect(opts[:batch_size]).to eq(1000)
      end
    end

    it 'persists the cursor on a partial flush failure (HTTPError mid-run)' do
      messages = Array.new(150) { |i| build_message(id: uuid(i + 1)) }
      stub_message_relation(messages)
      stub_reporting_event_relation([])

      call_count = 0
      allow(client).to receive(:post_batch) do
        call_count += 1
        raise EvoFlow::HTTPError.new('500', 500, nil) if call_count == 2

        {}
      end
      allow(Rails.logger).to receive(:warn)

      expect { described_class.new.perform(nil, 'dry_run' => false) }
        .to raise_error(EvoFlow::HTTPError)

      window = (1.year.ago).utc.strftime('%Y-%m-%d')
      expect(fake_alfred["backfill:cursor:#{window}:message"]).to eq(uuid(100))
    end
  end

  describe 'cursor key partitioning by from_date (M2)' do
    it 'includes the from_date YYYY-MM-DD in the cursor key' do
      stub_message_relation([build_message(id: uuid(10))])
      stub_reporting_event_relation([])

      described_class.new.perform(nil, 'dry_run' => false, 'from_date' => '2026-04-01T00:00:00Z')

      expect(fake_alfred.keys.grep(/^evo_flow_backfill:processed:message/)).not_to be_empty
      # Cursor was deleted at the end, but the key shape should have been the dated one;
      # we verify indirectly by checking no legacy (non-dated) key survives.
      expect(fake_alfred.keys.grep(/^backfill:cursor:message$/)).to be_empty
    end
  end

  describe 'skip conditions' do
    it 'skips and increments :skipped when conversation contact is missing' do
      msg_no_contact = build_message(id: uuid(10), conversation: build_conversation(contact_id: nil))
      stub_message_relation([msg_no_contact])
      stub_reporting_event_relation([])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(client).not_to have_received(:post_batch)
      expect(fake_alfred['evo_flow_backfill:skipped:message']).to eq('1')
    end

    it 'skips ReportingEvent rows with nil event_start_time (H4)' do
      re_no_time = build_reporting_event(id: uuid(20), event_start_time: nil)
      stub_message_relation([])
      stub_reporting_event_relation([re_no_time])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(client).not_to have_received(:post_batch)
      expect(fake_alfred['evo_flow_backfill:skipped:reporting_event']).to eq('1')
    end
  end

  describe 'fail-loud on unmapped ReportingEvent (AC6)' do
    let(:listener) do
      Class.new do
        attr_reader :received

        def evo_flow_backfill_dropped(args)
          @received = args
        end
      end.new
    end

    it 'raises EvoFlow::InvalidEventName + broadcasts :evo_flow_backfill_dropped' do
      stub_message_relation([])
      stub_reporting_event_relation([build_reporting_event(id: uuid(20), name: 'unknown_legacy_event')])
      allow(Rails.logger).to receive(:error)

      Wisper.subscribe(listener) do
        expect { described_class.new.perform(nil, 'dry_run' => false) }
          .to raise_error(EvoFlow::InvalidEventName)
      end

      expect(listener.received).to be_present
      expect(listener.received[:data][:reason]).to eq(:invalid_event_name)
      expect(listener.received[:data][:error_message]).to include('unknown_legacy_event')
    end
  end

  describe 'F4 ConfigurationError drop' do
    it 'logs + broadcasts :evo_flow_backfill_dropped and does NOT re-raise' do
      allow(EvoFlow::Client).to receive(:new)
        .and_raise(EvoFlow::ConfigurationError, 'AUTH_APIKEY_INTEGRATION_LOCAL is not set')
      stub_message_relation([])
      stub_reporting_event_relation([])
      allow(Rails.logger).to receive(:error)

      listener = Class.new do
        attr_reader :received

        def evo_flow_backfill_dropped(args)
          @received = args
        end
      end.new

      Wisper.subscribe(listener) do
        expect { described_class.new.perform(nil, 'dry_run' => false) }.not_to raise_error
      end

      expect(listener.received[:data][:reason]).to eq(:configuration_error)
    end
  end

  describe 'PII redaction in flush failure log (AC7)' do
    it 'logs the sample payload with properties redacted on HTTPError' do
      stub_message_relation([build_message(id: uuid(10), content: 'CPF 12345678900')])
      stub_reporting_event_relation([])
      allow(client).to receive(:post_batch).and_raise(EvoFlow::HTTPError.new('boom', 500, nil))
      logged = []
      allow(Rails.logger).to receive(:warn) { |m| logged << m }

      expect { described_class.new.perform(nil, 'dry_run' => false) }
        .to raise_error(EvoFlow::HTTPError)

      expect(logged.join).to include('[redacted]')
      expect(logged.join).not_to include('CPF 12345678900')
    end

    it 'increments :flush_attempts_failed (not :failed) on HTTPError so retry storms do not inflate the per-record counter (M3)' do
      stub_message_relation([build_message(id: uuid(10))])
      stub_reporting_event_relation([])
      allow(client).to receive(:post_batch).and_raise(EvoFlow::HTTPError.new('boom', 500, nil))
      allow(Rails.logger).to receive(:warn)

      expect { described_class.new.perform(nil, 'dry_run' => false) }.to raise_error(EvoFlow::HTTPError)

      expect(fake_alfred['evo_flow_backfill:flush_attempts_failed:message']).to eq('1')
      expect(fake_alfred['evo_flow_backfill:failed:message']).to be_nil
    end
  end

  describe 'from_date parsing (AC10, H3)' do
    it 'defaults to 1.year.ago when not provided' do
      stub_message_relation([])
      stub_reporting_event_relation([])

      worker = described_class.new
      worker.perform(nil, 'dry_run' => true)
      from_date = worker.instance_variable_get(:@from_date)

      expect(from_date).to be_within(5.seconds).of(1.year.ago)
    end

    it 'parses an explicit ISO8601 from_date' do
      stub_message_relation([])
      stub_reporting_event_relation([])

      worker = described_class.new
      worker.perform(nil, 'dry_run' => true, 'from_date' => '2026-01-01T00:00:00Z')

      expect(worker.instance_variable_get(:@from_date))
        .to eq(Time.iso8601('2026-01-01T00:00:00Z'))
    end

    it 'raises ArgumentError on a malformed from_date (no silent fallback)' do
      stub_message_relation([])
      stub_reporting_event_relation([])

      expect { described_class.new.perform(nil, 'dry_run' => true, 'from_date' => 'garbage') }
        .to raise_error(ArgumentError)
    end
  end

  describe 'retries exhausted -> Wisper :evo_flow_backfill_failed' do
    let(:listener) do
      Class.new do
        attr_reader :received

        def evo_flow_backfill_failed(args)
          @received = args
        end
      end.new
    end

    it 'broadcasts with account_id + sanitized error (no source field — M1)' do
      job = { 'args' => [nil, {}], 'class' => described_class.name }
      exception = EvoFlow::HTTPError.new('boom', 500, nil)

      Wisper.subscribe(listener) do
        described_class.sidekiq_retries_exhausted_block.call(job, exception)
      end

      expect(listener.received).to be_present
      expect(listener.received[:data]).to include(:account_id, :error)
      expect(listener.received[:data]).not_to include(:source)
      expect(listener.received[:data][:error]).to include('boom')
    end
  end
end
