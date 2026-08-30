# frozen_string_literal: true

require 'rails_helper'

# The send-response contract consumed by SendOnWhatsappService.
RSpec.describe Whatsapp::Providers::ZapiService do
  let(:whatsapp_channel) do
    instance_double(Channel::Whatsapp,
                    provider_config: { 'instance_id' => 'inst', 'token' => 'tok', 'client_token' => 'ct' })
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  describe '#process_response' do
    it 'returns the message id on success' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'zaapId' => 'ZAAP1', 'messageId' => 'ZAPI123', 'id' => 'ZAPI123' },
        body: '{}'
      )

      expect(service.send(:process_response, response)).to eq('ZAPI123')
    end

    it 'returns true when a 200 carries none of the id fields' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'value' => true },
        body: '{}'
      )

      expect(service.send(:process_response, response)).to be(true)
    end

    it 'returns nil and records the reason on error' do
      response = instance_double(
        HTTParty::Response,
        success?: false,
        parsed_response: { 'error' => 'phone not found' },
        body: '{"error":"phone not found"}'
      )

      expect(service.send(:process_response, response)).to be_nil
      expect(service.last_delivery_error).to eq('phone not found')
    end
  end
end
