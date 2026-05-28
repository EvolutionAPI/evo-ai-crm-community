require 'rails_helper'
require 'webmock/rspec'

RSpec.describe EvoFlow::Client do
  let(:api_url) { 'http://evo-flow:3000/api/v1' }
  let(:api_key) { 'xyz' }
  let(:client) { described_class.new(api_url: api_url, api_key: api_key, timeout: 5) }
  let(:track_url) { "#{api_url}/events/track" }
  let(:payload) { { event: 'contact.created', contactId: '42' } }

  describe '#post' do
    it 'POSTs to the full /api/v1 URL with auth + json headers (AC1)' do
      stub = stub_request(:post, track_url)
             .with(
               body: payload.to_json,
               headers: {
                 'X-Integration-API-Key' => api_key,
                 'Content-Type' => 'application/json'
               }
             )
             .to_return(
               status: 200,
               body: { messageId: 'm-1', status: 'queued' }.to_json,
               headers: { 'Content-Type' => 'application/json' }
             )

      result = client.post('/events/track', payload)

      expect(stub).to have_been_requested
      expect(result).to include('messageId' => 'm-1', 'status' => 'queued')
    end

    it 'keeps the /api/v1 prefix and never hits the bare root (F8)' do
      good = stub_request(:post, track_url).to_return(status: 200, body: '{}')
      root = stub_request(:post, 'http://evo-flow:3000/events/track')

      client.post('/events/track', payload)
      client.post('events/track', payload)       # no leading slash
      client.post('//events/track', payload)     # doubled leading slash

      expect(good).to have_been_requested.times(3)
      expect(root).not_to have_been_requested
    end

    it 'raises EvoFlow::HTTPError with #code and #response on HTTP 500 (AC2)' do
      stub_request(:post, track_url).to_return(status: 500, body: 'boom')

      expect { client.post('/events/track', payload) }
        .to raise_error(EvoFlow::HTTPError) { |error|
          expect(error.code).to eq(500)
          expect(error.response).to be_present
          expect(error.response.body).to eq('boom')
        }
    end

    it 'raises EvoFlow::HTTPError with nil code on a refused connection (AC2b)' do
      stub_request(:post, track_url).to_raise(Errno::ECONNREFUSED)

      expect { client.post('/events/track', payload) }
        .to raise_error(EvoFlow::HTTPError) { |error|
          expect(error.code).to be_nil
          expect(error.message).to include('evo-flow request failed')
        }
    end

    it 'raises EvoFlow::HTTPError with nil code on a timeout (AC2b)' do
      stub_request(:post, track_url).to_timeout

      expect { client.post('/events/track', payload) }
        .to raise_error(EvoFlow::HTTPError) { |error| expect(error.code).to be_nil }
    end

    it 'raises EvoFlow::HTTPError on an unparseable 2xx body (F2)' do
      stub_request(:post, track_url)
        .to_return(status: 200, body: '{not-json', headers: { 'Content-Type' => 'application/json' })

      expect { client.post('/events/track', payload) }
        .to raise_error(EvoFlow::HTTPError) { |error|
          expect(error.code).to eq(200)
          expect(error.message).to include('unparseable')
        }
    end

    it 'redacts any 4xx body (auth + validation echoes) (L2)' do
      logged = []
      allow(Rails.logger).to receive(:error) { |m| logged << m }

      [400, 401, 403, 422, 429].each do |code|
        stub_request(:post, track_url).to_return(status: code, body: "echo-input-#{code} secret=xyz")
        expect { client.post('/events/track', payload) }.to raise_error(EvoFlow::HTTPError) { |error|
          expect(error.message).to include('[redacted: 4xx body]')
          expect(error.message).not_to include('echo-input')
        }
      end
      expect(logged.join).not_to include('echo-input')
    end

    it 'wraps OpenSSL::SSL::SSLError as HTTPError with nil code (L4)' do
      stub_request(:post, track_url).to_raise(OpenSSL::SSL::SSLError.new('handshake failed'))

      expect { client.post('/events/track', payload) }
        .to raise_error(EvoFlow::HTTPError) { |error|
          expect(error.code).to be_nil
          expect(error.message).to include('evo-flow request failed')
        }
    end
  end

  describe '#get' do
    let(:events_path) { '/contacts/42/events' }
    let(:events_url) { "#{api_url}/contacts/42/events" }

    it 'GETs the full /api/v1 URL with the integration API key header and returns parsed body' do
      stub = stub_request(:get, events_url)
             .with(
               query: { 'limit' => '10' },
               headers: { 'X-Integration-API-Key' => api_key }
             )
             .to_return(
               status: 200,
               body: { events: [], pagination: { hasNext: false } }.to_json,
               headers: { 'Content-Type' => 'application/json' }
             )

      result = client.get(events_path, limit: 10)

      expect(stub).to have_been_requested
      expect(result).to include('events' => [])
      expect(result['pagination']).to include('hasNext' => false)
    end

    it 'omits keys whose value is nil from the outbound query string (params.compact)' do
      stub = stub_request(:get, events_url)
             .with(query: hash_including('limit' => '10'))
             .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })

      client.get(events_path, limit: 10, cursor: nil)

      expect(stub).to have_been_requested
      expect(WebMock).not_to have_requested(:get, events_url).with(query: hash_including('cursor'))
    end

    it 'raises EvoFlow::HTTPError with code 500 on upstream 5xx' do
      stub_request(:get, events_url).to_return(status: 500, body: 'boom')

      expect { client.get(events_path) }
        .to raise_error(EvoFlow::HTTPError) { |error|
          expect(error.code).to eq(500)
          expect(error.response.body).to eq('boom')
        }
    end

    it 'raises EvoFlow::HTTPError with code 404 on upstream 4xx' do
      stub_request(:get, events_url).to_return(status: 404, body: { error: 'nope' }.to_json,
                                               headers: { 'Content-Type' => 'application/json' })

      expect { client.get(events_path) }
        .to raise_error(EvoFlow::HTTPError) { |error| expect(error.code).to eq(404) }
    end

    it 'raises EvoFlow::HTTPError with nil code on a network timeout' do
      stub_request(:get, events_url).to_timeout

      expect { client.get(events_path) }
        .to raise_error(EvoFlow::HTTPError) { |error| expect(error.code).to be_nil }
    end
  end

  describe '#post_batch' do
    let(:batch_url) { "#{api_url}/events/batch" }
    let(:events) do
      [
        { messageId: 'm-1', contactId: '42', event: 'conversation.activity', properties: {}, timestamp: '2026-01-01T00:00:00Z' },
        { messageId: 'm-2', contactId: '43', event: 'conversation.activity', properties: {}, timestamp: '2026-01-01T00:00:01Z' }
      ]
    end

    it 'POSTs {events: [...]} to /events/batch with auth + json headers' do
      stub = stub_request(:post, batch_url)
             .with(
               body: { events: events }.to_json,
               headers: {
                 'X-Integration-API-Key' => api_key,
                 'Content-Type' => 'application/json'
               }
             )
             .to_return(status: 200, body: '{}')

      client.post_batch(events)

      expect(stub).to have_been_requested
    end

    it 'propagates EvoFlow::HTTPError from #post on non-2xx' do
      stub_request(:post, batch_url).to_return(status: 500, body: 'boom')

      expect { client.post_batch(events) }
        .to raise_error(EvoFlow::HTTPError) { |error| expect(error.code).to eq(500) }
    end

    it 'propagates EvoFlow::HTTPError on transport failure (refused connection)' do
      stub_request(:post, batch_url).to_raise(Errno::ECONNREFUSED)

      expect { client.post_batch(events) }
        .to raise_error(EvoFlow::HTTPError) { |error| expect(error.code).to be_nil }
    end
  end

  describe 'configuration safety' do
    it 'raises ConfigurationError when the API key is blank (F13)' do
      expect { described_class.new(api_url: api_url, api_key: '') }
        .to raise_error(EvoFlow::ConfigurationError, /not set/)
      expect { described_class.new(api_url: api_url, api_key: nil) }
        .to raise_error(EvoFlow::ConfigurationError)
    end

    it 'rejects an invalid/missing scheme in any environment (M2)' do
      # Reproduces the EVO_FLOW_API_URL=evo-flow:3000 typo: URI parses 'evo-flow'
      # as the scheme. Must fail fast even in development/test.
      expect { described_class.new(api_url: 'evo-flow:3000/api/v1', api_key: 'k') }
        .to raise_error(EvoFlow::ConfigurationError, /invalid or missing scheme/)
      expect { described_class.new(api_url: 'ftp://evo-flow/api/v1', api_key: 'k') }
        .to raise_error(EvoFlow::ConfigurationError, /invalid or missing scheme/)
    end

    context 'when in production' do
      before { allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production')) }

      it 'refuses cleartext http without an explicit opt-out (F1)' do
        expect { described_class.new(api_url: 'http://evo-flow:3000/api/v1', api_key: 'k') }
          .to raise_error(EvoFlow::ConfigurationError, /cleartext/)
      end

      it 'allows https' do
        expect { described_class.new(api_url: 'https://evo-flow/api/v1', api_key: 'k') }
          .not_to raise_error
      end

      it 'accepts EVO_FLOW_ALLOW_INSECURE in any of true/1/yes/on (case-insensitive) (L1)' do
        allow(ENV).to receive(:fetch).and_call_original

        %w[true TRUE True 1 yes YES on On].each do |val|
          allow(ENV).to receive(:fetch).with('EVO_FLOW_ALLOW_INSECURE', '').and_return(val)
          expect { described_class.new(api_url: 'http://evo-flow:3000/api/v1', api_key: 'k') }
            .not_to raise_error
        end
      end

      it 'rejects non-truthy values for EVO_FLOW_ALLOW_INSECURE' do
        allow(ENV).to receive(:fetch).and_call_original

        ['', 'maybe', '0', 'false'].each do |val|
          allow(ENV).to receive(:fetch).with('EVO_FLOW_ALLOW_INSECURE', '').and_return(val)
          expect { described_class.new(api_url: 'http://evo-flow:3000/api/v1', api_key: 'k') }
            .to raise_error(EvoFlow::ConfigurationError, /cleartext/)
        end
      end
    end
  end

  describe 'ENV defaults (F9 — consistent ENV.fetch)' do
    it 'falls back to the documented default base URL' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch)
        .with('EVO_FLOW_API_URL', described_class::DEFAULT_API_URL)
        .and_return(described_class::DEFAULT_API_URL)
      allow(ENV).to receive(:fetch).with('AUTH_APIKEY_INTEGRATION_LOCAL', nil).and_return('k')

      stub = stub_request(:post, 'http://evo-flow:3000/api/v1/events/track')
             .to_return(status: 200, body: '{}')

      described_class.new.post('/events/track', payload)

      expect(stub).to have_been_requested
    end
  end
end
