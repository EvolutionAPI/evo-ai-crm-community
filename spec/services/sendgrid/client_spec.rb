# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# EVO-1251 (story 9.4): Sendgrid::Client is pure transport over POST
# /v3/mail/send. These specs assert the payload shape (custom_args,
# bypass_unsubscribe_management, rendered html) and the response -> status map.
RSpec.describe Sendgrid::Client do
  subject(:client) { described_class.new(channel) }

  let(:mail_send_url) { 'https://api.sendgrid.com/v3/mail/send' }

  let(:channel) do
    instance_double(
      Channel::Sendgrid,
      api_key: 'SG.key-x',
      from_email: 'news@acme.com',
      from_name: 'Acme News',
      reply_to: nil
    )
  end
  let(:contact) { instance_double(Contact, email: 'jane@acme.com') }
  let(:conversation) do
    instance_double(
      Conversation,
      contact: contact,
      contact_id: 'contact-uuid',
      display_id: 42,
      additional_attributes: { 'mail_subject' => 'Promo' }
    )
  end
  let(:message) do
    instance_double(
      Message,
      id: 'msg-uuid',
      conversation: conversation,
      content: '<h1>Hi</h1>',
      additional_attributes: { 'campaign_id' => 'camp-uuid' }
    )
  end
  let(:status_service) { instance_double(Messages::StatusUpdateService, perform: true) }

  describe '#deliver — success (202)' do
    before { stub_request(:post, mail_send_url).to_return(status: 202, body: '') }

    it 'posts to mail/send with the channel api key, from, to, html and custom_args' do
      allow(Messages::StatusUpdateService).to receive(:new).with(message, 'sent').and_return(status_service)

      client.deliver(message: message)

      expect(a_request(:post, mail_send_url).with do |req|
        body = JSON.parse(req.body)
        personalization = body['personalizations'].first
        req.headers['Authorization'] == 'Bearer SG.key-x' &&
          personalization['to'] == [{ 'email' => 'jane@acme.com' }] &&
          personalization['custom_args'] == {
            'contact_id' => 'contact-uuid', 'message_id' => 'msg-uuid', 'campaign_id' => 'camp-uuid'
          } &&
          body['from'] == { 'email' => 'news@acme.com', 'name' => 'Acme News' } &&
          body['subject'] == 'Promo' &&
          body['content'] == [{ 'type' => 'text/html', 'value' => '<h1>Hi</h1>' }]
      end).to have_been_made
    end

    it 'enables mail_settings.bypass_unsubscribe_management' do
      allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)

      client.deliver(message: message)

      expect(a_request(:post, mail_send_url).with do |req|
        JSON.parse(req.body).dig('mail_settings', 'bypass_unsubscribe_management', 'enable') == true
      end).to have_been_made
    end

    it 'marks the message sent and returns success' do
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'sent').and_return(status_service)

      result = client.deliver(message: message)

      expect(result).to include(success: true, status: 202)
    end
  end

  describe '#deliver — provider rejects (4xx/5xx)' do
    it 'raises InvalidApiKeyError and marks failed on 401' do
      stub_request(:post, mail_send_url).to_return(status: 401, body: '{"errors":[]}')
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed', 'SendGrid mail/send failed: 401').and_return(status_service)

      expect { client.deliver(message: message) }.to raise_error(Sendgrid::InvalidApiKeyError)
    end

    it 'raises ApiError and marks failed on 400, redacting the 4xx body in the log' do
      stub_request(:post, mail_send_url).to_return(status: 400, body: 'leaky-detail')
      allow(Messages::StatusUpdateService).to receive(:new).and_return(status_service)
      expect(Rails.logger).to receive(:error).with(/sg_response_status=400/).and_call_original
      expect(Rails.logger).not_to receive(:error).with(/leaky-detail/)

      expect { client.deliver(message: message) }.to raise_error(Sendgrid::ApiError)
    end

    it 'wraps transport failures as ServiceUnavailableError and marks the message failed' do
      stub_request(:post, mail_send_url).to_timeout
      expect(Messages::StatusUpdateService).to receive(:new).with(message, 'failed', /SendGrid transport error/).and_return(status_service)

      expect { client.deliver(message: message) }.to raise_error(Sendgrid::ServiceUnavailableError)
    end
  end
end
