# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Whatsapp::Providers::EvolutionService do
  let(:provider_config) do
    {
      'api_url' => 'https://evo.example.com',
      'admin_token' => 'test-token',
      'instance_name' => 'test-instance'
    }
  end
  let(:whatsapp_channel) { instance_double(Channel::Whatsapp, provider_config: provider_config) }
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }
  let(:phone_number) { '+5511999999999' }
  let(:success_response) do
    instance_double(
      HTTParty::Response,
      success?: true,
      parsed_response: { 'key' => { 'id' => 'msg-id-123' } }
    )
  end

  describe '#fetch_profile_picture_url' do
    it 'POSTs the phone number to /chat/fetchProfilePictureUrl/{instance} and returns the URL' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'profilePictureUrl' => 'https://cdn.example.com/p.jpg' }
      )
      allow(HTTParty).to receive(:post).and_return(response)

      url = service.fetch_profile_picture_url(phone_number)

      expect(url).to eq('https://cdn.example.com/p.jpg')
      expect(HTTParty).to have_received(:post) do |request_url, opts|
        expect(request_url).to eq('https://evo.example.com/chat/fetchProfilePictureUrl/test-instance')
        expect(JSON.parse(opts[:body])).to eq('number' => '5511999999999')
        expect(opts[:headers]['apikey']).to eq('test-token')
      end
    end

    it 'falls back to nested data.profilePictureUrl shape' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'data' => { 'profilePictureUrl' => 'https://cdn.example.com/nested.jpg' } }
      )
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.fetch_profile_picture_url(phone_number)).to eq('https://cdn.example.com/nested.jpg')
    end

    it 'returns nil and logs when the upstream call fails' do
      response = instance_double(HTTParty::Response, success?: false, code: 502)
      allow(HTTParty).to receive(:post).and_return(response)

      expect(service.fetch_profile_picture_url(phone_number)).to be_nil
    end

    it 'returns nil when 200 OK body carries an error key' do
      response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'error' => 'instance_disconnected', 'message' => 'instance not connected' }
      )
      allow(HTTParty).to receive(:post).and_return(response)
      allow(Rails.logger).to receive(:warn)

      expect(service.fetch_profile_picture_url(phone_number)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/200 OK with error body/)
    end

    it 'returns nil and rescues network errors' do
      allow(HTTParty).to receive(:post).and_raise(SocketError, 'connection refused')

      expect { service.fetch_profile_picture_url(phone_number) }.not_to raise_error
      expect(service.fetch_profile_picture_url(phone_number)).to be_nil
    end

    it 'returns nil for blank input without hitting the network' do
      expect(HTTParty).not_to receive(:post)
      expect(service.fetch_profile_picture_url('')).to be_nil
      expect(service.fetch_profile_picture_url(nil)).to be_nil
    end
  end

  describe '#send_text_message (HTML to WhatsApp formatting)' do
    it 'converts bold HTML to WhatsApp bold' do
      message = instance_double('Message', content: '<strong>Hello</strong> World', attachments: double(present?: false))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('*Hello* World')
      end
    end

    it 'converts italic HTML to WhatsApp italic' do
      message = instance_double('Message', content: '<em>italic</em> text', attachments: double(present?: false))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('_italic_ text')
      end
    end

    it 'converts code HTML to WhatsApp monospace' do
      message = instance_double('Message', content: 'use <code>method()</code> here', attachments: double(present?: false))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('use `method()` here')
      end
    end

    it 'converts mixed formatting correctly' do
      message = instance_double('Message',
                                content: '<p><strong>Title</strong></p><p>Some <em>italic</em> and <code>code</code></p>',
                                attachments: double(present?: false))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include('*Title*')
        expect(body['text']).to include('_italic_')
        expect(body['text']).to include('`code`')
        expect(body['text']).not_to match(/<[^>]+>/)
      end
    end

    it 'preserves plain text content unchanged' do
      message = instance_double('Message', content: 'Hello World', attachments: double(present?: false))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('Hello World')
      end
    end

    it 'converts <br> tags to newlines' do
      message = instance_double('Message', content: 'Line 1<br>Line 2<br/>Line 3', attachments: double(present?: false))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include("Line 1\nLine 2\nLine 3")
      end
    end

    it 'converts <p> blocks to double newlines' do
      message = instance_double('Message', content: '<p>Paragraph 1</p><p>Paragraph 2</p>', attachments: double(present?: false))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include("Paragraph 1\n\nParagraph 2")
      end
    end

    it 'converts list items to dashes' do
      message = instance_double('Message',
                                content: '<ul><li>Item 1</li><li>Item 2</li></ul>',
                                attachments: double(present?: false))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to include('- Item 1')
        expect(body['text']).to include('- Item 2')
      end
    end

    it 'strips HTML-only content to empty string' do
      message = instance_double('Message', content: '<p></p>', attachments: double(present?: false))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('')
      end
    end

    it 'handles string message (template fallback)' do
      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send(:send_text_message, phone_number, '<b>bold template</b>')

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['text']).to eq('*bold template*')
      end
    end
  end

  describe '#send_media_message (caption formatting)' do
    let(:file_double) { instance_double('AttachmentFile', filename: double(to_s: 'photo.jpg'), attached?: false) }
    let(:attachment) do
      instance_double('Attachment', file_type: 'image', file: file_double,
                                    file_url: 'https://s3.example.com/photo.jpg')
    end

    it 'converts HTML in caption to WhatsApp formatting' do
      message = instance_double('Message', content: '<p>Check this <b>image</b></p>',
                                           attachments: double(present?: true, first: attachment))

      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send_message(phone_number, message)

      expect(HTTParty).to have_received(:post) do |_url, opts|
        body = JSON.parse(opts[:body])
        expect(body['caption']).to include('*image*')
        expect(body['caption']).not_to match(/<[^>]+>/)
      end
    end
  end
end
