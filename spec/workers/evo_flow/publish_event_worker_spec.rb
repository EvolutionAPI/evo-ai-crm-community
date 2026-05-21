require 'rails_helper'

RSpec.describe EvoFlow::PublishEventWorker, type: :job do
  let(:client) { instance_double(EvoFlow::Client) }
  let(:path) { '/events/track' }
  let(:payload) do
    { 'messageId' => 'm-1', 'contactId' => '42', 'event' => 'contact.created',
      'properties' => { 'email' => 'pii@example.com' } }
  end

  before { allow(EvoFlow::Client).to receive(:new).and_return(client) }

  describe '#perform' do
    it 'forwards path + payload to EvoFlow::Client#post (happy path)' do
      allow(client).to receive(:post).and_return('messageId' => 'm-1', 'status' => 'queued')

      described_class.new.perform(path, payload)

      expect(client).to have_received(:post).with(path, payload)
    end

    it 're-raises EvoFlow::HTTPError so Sidekiq counts the retry' do
      allow(client).to receive(:post).and_raise(EvoFlow::HTTPError.new('500', 500, nil))

      expect { described_class.new.perform(path, payload) }
        .to raise_error(EvoFlow::HTTPError)
    end

    it 're-raises non-HTTPError too so every failure path counts as a retry (F4)' do
      allow(client).to receive(:post).and_raise(ArgumentError, 'bad args')

      expect { described_class.new.perform(path, payload) }
        .to raise_error(ArgumentError)
    end

    it 'swallows EvoFlow::InvalidEventName so Sidekiq does NOT retry (F4 exception, AC3)' do
      allow(client).to receive(:post)
        .and_raise(EvoFlow::InvalidEventName, 'bad')
      logged = []
      allow(Rails.logger).to receive(:error) { |m| logged << m }

      expect { described_class.new.perform(path, payload) }.not_to raise_error
      expect(logged.join).to include('dropped: invalid event_name').and include('bad')
    end

    it 'swallows EvoFlow::ConfigurationError so Sidekiq does NOT retry (F4 exception)' do
      allow(client).to receive(:post)
        .and_raise(EvoFlow::ConfigurationError, 'AUTH_APIKEY_INTEGRATION_LOCAL is not set')
      logged = []
      allow(Rails.logger).to receive(:error) { |m| logged << m }

      expect { described_class.new.perform(path, payload) }.not_to raise_error
      expect(logged.join).to include('dropped: configuration error')
        .and include('AUTH_APIKEY_INTEGRATION_LOCAL')
    end
  end

  describe 'F4 drops -> Wisper :evo_flow_publish_dropped (M-1)' do
    let(:listener) do
      Class.new do
        attr_reader :received

        def evo_flow_publish_dropped(args)
          @received = args
        end
      end.new
    end

    it 'broadcasts :evo_flow_publish_dropped with reason: :invalid_event_name on InvalidEventName' do
      allow(client).to receive(:post).and_raise(EvoFlow::InvalidEventName, 'bad name')
      allow(Rails.logger).to receive(:error)

      Wisper.subscribe(listener) do
        described_class.new.perform(path, payload)
      end

      expect(listener.received).to be_present
      expect(listener.received[:data][:reason]).to eq(:invalid_event_name)
      expect(listener.received[:data][:path]).to eq(path)
      expect(listener.received[:data][:error_message]).to include('bad name')
    end

    it 'broadcasts :evo_flow_publish_dropped with reason: :configuration_error on ConfigurationError' do
      allow(client).to receive(:post)
        .and_raise(EvoFlow::ConfigurationError, 'AUTH_APIKEY_INTEGRATION_LOCAL is not set')
      allow(Rails.logger).to receive(:error)

      Wisper.subscribe(listener) do
        described_class.new.perform(path, payload)
      end

      expect(listener.received).to be_present
      expect(listener.received[:data][:reason]).to eq(:configuration_error)
      expect(listener.received[:data][:path]).to eq(path)
      expect(listener.received[:data][:error_message]).to include('AUTH_APIKEY_INTEGRATION_LOCAL')
    end

    it 'does NOT broadcast :evo_flow_publish_dropped on transient HTTPError (that path keeps :evo_flow_publish_failed semantics)' do
      allow(client).to receive(:post).and_raise(EvoFlow::HTTPError.new('500', 500, nil))
      allow(Rails.logger).to receive(:warn)

      Wisper.subscribe(listener) do
        expect { described_class.new.perform(path, payload) }.to raise_error(EvoFlow::HTTPError)
      end

      expect(listener.received).to be_nil
    end
  end

  describe '.sanitize_payload (F3)' do
    it 'redacts PII-bearing fields, keeps identifiers, tolerates symbol keys' do
      expect(described_class.sanitize_payload(payload)).to eq(
        'messageId' => 'm-1', 'contactId' => '42', 'event' => 'contact.created',
        'properties' => '[redacted]'
      )
      expect(described_class.sanitize_payload(traits: { email: 'x' }, contactId: '7'))
        .to eq(traits: '[redacted]', contactId: '7')
    end

    it 'passes non-hash payloads through untouched' do
      expect(described_class.sanitize_payload('raw')).to eq('raw')
    end
  end

  describe 'sidekiq configuration' do
    it 'uses the integrations queue and retry: 5 (overrides global 3)' do
      expect(described_class.sidekiq_options['queue']).to eq(:integrations)
      expect(described_class.sidekiq_options['retry']).to eq(5)
    end
  end

  describe 'retries exhausted -> Wisper :evo_flow_publish_failed (AC4)' do
    let(:listener) do
      Class.new do
        attr_reader :received

        def evo_flow_publish_failed(args)
          @received = args
        end
      end.new
    end

    it 'broadcasts with path + error and a PII-redacted payload (AC4 + F3)' do
      job = { 'args' => [path, payload], 'class' => described_class.name }
      exception = EvoFlow::HTTPError.new('boom', 500, nil)

      Wisper.subscribe(listener) do
        described_class.sidekiq_retries_exhausted_block.call(job, exception)
      end

      expect(listener.received).to be_present
      expect(listener.received[:data][:path]).to eq(path)
      expect(listener.received[:data][:error]).to eq('boom')
      expect(listener.received[:data][:payload]['properties']).to eq('[redacted]')
      expect(listener.received[:data][:payload]['messageId']).to eq('m-1')
    end

    it 'redacts long secret-like tokens out of ex.message before broadcast/log (M1)' do
      job = { 'args' => [path, payload], 'class' => described_class.name }
      leaked_token = 'a' * 40
      exception = ArgumentError.new("upstream said token=#{leaked_token} go away")
      logged = []
      allow(Rails.logger).to receive(:error) { |m| logged << m }

      Wisper.subscribe(listener) do
        described_class.sidekiq_retries_exhausted_block.call(job, exception)
      end

      expect(listener.received[:data][:error]).not_to include(leaked_token)
      expect(listener.received[:data][:error]).to include('[redacted]')
      expect(logged.join).not_to include(leaked_token)
    end
  end

  describe '.sanitize_error (M1)' do
    it 'redacts likely secrets (>=32 hex/base64) and is length-bounded' do
      ex = StandardError.new("hex=#{'f' * 64} long body: #{'x' * 600}")
      out = described_class.sanitize_error(ex)
      expect(out).to include('[redacted]')
      expect(out).not_to include('f' * 64)
      expect(out.length).to be <= 530 # 500 + '... (truncated)' suffix
    end

    it 'is idempotent (calling twice yields the same string)' do
      ex = StandardError.new("token=#{'a' * 50}")
      first = described_class.sanitize_error(ex)
      expect(described_class.sanitize_error(ex)).to eq(first)
    end

    it 'leaves short, token-free messages untouched' do
      expect(described_class.sanitize_error(StandardError.new('boom'))).to eq('boom')
    end
  end

  describe 'happy-path log when messageId is absent (L6)' do
    it 'logs messageId=<missing> instead of an empty value' do
      allow(client).to receive(:post).and_return({})
      logged = []
      allow(Rails.logger).to receive(:info) { |m| logged << m }

      described_class.new.perform(path, {}) # payload with no messageId
      described_class.new.perform(path, nil) # not even a hash

      expect(logged).to all(include('messageId=<missing>'))
    end
  end
end
