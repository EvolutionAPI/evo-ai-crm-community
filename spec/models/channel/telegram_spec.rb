# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channel::Telegram, type: :model do
  let(:token) { "telegram-token-#{SecureRandom.hex(4)}" }
  let(:channel) { described_class.new(bot_token: token) }

  describe 'token validation and webhook setup errors' do
    context 'when token is invalid' do
      it 'adds validation error instead of raising' do
        response = instance_double(HTTParty::Response, success?: false, parsed_response: { 'description' => 'Unauthorized' })
        allow(HTTParty).to receive(:get).and_return(response)

        expect(channel).not_to be_valid
        expect(channel.errors[:bot_token]).to include('Unauthorized')
      end
    end

    context 'when telegram token validation has network error' do
      it 'adds validation error instead of raising' do
        allow(HTTParty).to receive(:get).and_raise(Net::OpenTimeout, 'execution expired')

        expect(channel).not_to be_valid
        expect(channel.errors[:bot_token].join).to include('could not validate bot token')
      end
    end

    context 'when backend url env vars are missing' do
      it 'aborts save with descriptive error' do
        get_me_response = instance_double(
          HTTParty::Response,
          success?: true,
          parsed_response: { 'result' => { 'first_name' => 'MyBot', 'username' => 'my_bot' } }
        )

        allow(HTTParty).to receive(:get).and_return(get_me_response)
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('BACKEND_URL', nil).and_return(nil)
        allow(ENV).to receive(:fetch).with('FRONTEND_URL', nil).and_return(nil)
        expect(HTTParty).not_to receive(:post)

        expect(channel.save).to be(false)
        expect(channel.errors[:bot_token]).to include('error setting up the webhook: BACKEND_URL or FRONTEND_URL is missing')
      end

      it 'raises RecordNotSaved on save!' do
        get_me_response = instance_double(
          HTTParty::Response,
          success?: true,
          parsed_response: { 'result' => { 'first_name' => 'MyBot', 'username' => 'my_bot' } }
        )

        allow(HTTParty).to receive(:get).and_return(get_me_response)
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('BACKEND_URL', nil).and_return(nil)
        allow(ENV).to receive(:fetch).with('FRONTEND_URL', nil).and_return(nil)
        expect(HTTParty).not_to receive(:post)

        expect { channel.save! }.to raise_error(ActiveRecord::RecordNotSaved)
      end
    end

    context 'when telegram api is unreachable during webhook setup' do
      it 'aborts save with connectivity error' do
        get_me_response = instance_double(
          HTTParty::Response,
          success?: true,
          parsed_response: { 'result' => { 'first_name' => 'MyBot', 'username' => 'my_bot' } }
        )

        allow(HTTParty).to receive(:get).and_return(get_me_response)
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('BACKEND_URL', nil).and_return('https://api.example.com')
        allow(HTTParty).to receive(:post).and_raise(SocketError, 'getaddrinfo: Name or service not known')

        expect(channel.save).to be(false)
        expect(channel.errors[:bot_token].join).to include('could not connect to Telegram API')
      end
    end

    context 'when token is valid and webhook setup succeeds' do
      it 'saves the channel successfully' do
        get_me_response = instance_double(
          HTTParty::Response,
          success?: true,
          parsed_response: { 'result' => { 'first_name' => 'MyBot', 'username' => 'my_bot' } }
        )
        delete_webhook_response = instance_double(HTTParty::Response, success?: true, parsed_response: {})
        set_webhook_response = instance_double(HTTParty::Response, success?: true, parsed_response: {})

        allow(HTTParty).to receive(:get).and_return(get_me_response)
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('BACKEND_URL', nil).and_return('https://api.example.com')
        allow(HTTParty).to receive(:post).with("#{channel.telegram_api_url}/deleteWebhook").and_return(delete_webhook_response)
        allow(HTTParty).to receive(:post).with(
          "#{channel.telegram_api_url}/setWebhook",
          body: { url: "https://api.example.com/webhooks/telegram/#{token}" }
        ).and_return(set_webhook_response)

        expect { channel.save! }.to change(described_class, :count).by(1)
        expect(channel.bot_name).to eq('MyBot')
      end
    end
  end

  describe '#process_error' do
    let(:process_error_channel) { described_class.allocate }
    let(:message) { instance_double(Message) }
    let(:response) { instance_double(HTTParty::Response, parsed_response: parsed) }
    let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

    context 'when the Bot API returned an error' do
      let(:parsed) { { 'ok' => false, 'error_code' => 400, 'description' => 'Bad Request' } }

      it 'delegates failed status with comma-formatted external_error' do
        expect(Messages::StatusUpdateService)
          .to receive(:new).with(message, 'failed', '400, Bad Request').and_return(status_service)

        process_error_channel.process_error(message, response)
      end
    end

    context 'when ok is true' do
      let(:parsed) { { 'ok' => true } }

      it 'is a no-op' do
        expect(Messages::StatusUpdateService).not_to receive(:new)
        process_error_channel.process_error(message, response)
      end
    end
  end
end
