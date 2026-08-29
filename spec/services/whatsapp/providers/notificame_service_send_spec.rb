# frozen_string_literal: true

require 'rails_helper'

# CRM-358: the send-response contract consumed by SendOnWhatsappService.
RSpec.describe Whatsapp::Providers::NotificameService do
  let(:whatsapp_channel) do
    instance_double(Channel::Whatsapp, provider_config: { 'api_key' => 'token' })
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  describe '#process_response' do
    it 'returns the message id on success' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'messageId' => 'NM123' },
        body: '{}'
      )

      expect(service.send(:process_response, response)).to eq('NM123')
    end

    # A success shape whose id only store_message_ids understands
    # (providerMessageId) must still read as success at the caller.
    it 'returns true when the success shape carries no extractable message id' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'messageStatus' => { 'code' => 'SENT', 'providerMessageId' => 'cHJvdg==' } },
        body: '{}'
      )

      expect(service.send(:process_response, response)).to be(true)
    end

    it 'returns nil and records the reason on error' do
      response = instance_double(
        HTTParty::Response,
        success?: false,
        parsed_response: { 'messageStatus' => { 'code' => 'ERROR', 'error' => { 'message' => 'invalid token' } } },
        body: '{"messageStatus":{"code":"ERROR"}}'
      )

      expect(service.send(:process_response, response)).to be_nil
      expect(service.last_delivery_error).to eq('invalid token')
    end
  end
end
