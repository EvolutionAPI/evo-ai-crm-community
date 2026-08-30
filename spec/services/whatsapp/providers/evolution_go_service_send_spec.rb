# frozen_string_literal: true

require 'rails_helper'

# The send-response contract consumed by SendOnWhatsappService: a delivered
# send without an ID must not read as a failure.
RSpec.describe Whatsapp::Providers::EvolutionGoService do
  let(:whatsapp_channel) do
    instance_double(Channel::Whatsapp, provider_config: { 'api_key' => 'token', 'instance_name' => 'inst' })
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  describe '#process_evolution_go_response' do
    it 'returns the message id when the API provides one' do
      response = instance_double(
        HTTParty::Response,
        success?: true, code: 200,
        parsed_response: { 'data' => { 'Info' => { 'ID' => 'GO123' } }, 'message' => 'success' },
        body: '{}'
      )

      expect(service.send(:process_evolution_go_response, response)).to eq('GO123')
    end

    it 'returns true (success without id) when HTTP 200 carries no ID' do
      response = instance_double(
        HTTParty::Response,
        success?: true, code: 200,
        parsed_response: { 'message' => 'success' },
        body: '{}'
      )

      expect(service.send(:process_evolution_go_response, response)).to be(true)
    end

    it 'raises on HTTP error (handled by SendReplyJob rescue)' do
      response = instance_double(
        HTTParty::Response,
        success?: false, code: 500,
        parsed_response: {},
        body: 'boom'
      )

      expect { service.send(:process_evolution_go_response, response) }
        .to raise_error(/HTTP 500/)
    end
  end
end
