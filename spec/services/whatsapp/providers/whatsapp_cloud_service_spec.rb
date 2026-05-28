# frozen_string_literal: true

require 'rails_helper'
require 'tempfile'

RSpec.describe Whatsapp::Providers::WhatsappCloudService do
  unless const_defined?(:MessageStub)
    MessageStub = Struct.new(:id, :content_attributes, :external_error, :status, keyword_init: true) do
      attr_reader :saved

      def save!
        @saved = true
      end
    end
  end

  let(:whatsapp_channel) do
    instance_double(
      Channel::Whatsapp,
      provider_config: {
        'api_key' => 'api-token',
        'phone_number_id' => '12345'
      }
    )
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }
  let(:blob) { instance_double('ActiveStorage::Blob', content_type: 'audio/webm') }
  let(:file) { instance_double('AttachmentFile', blob: blob, filename: 'voice.webm') }
  let(:attachment) { instance_double('Attachment', file: file) }
  let(:message) { MessageStub.new(id: 42, content_attributes: {}) }
  let(:temp_file) { instance_double(Tempfile, path: '/tmp/voice.webm') }

  before do
    allow(service).to receive(:download_attachment_to_temp).and_return(temp_file)

    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(temp_file.path).and_return(true)
    allow(File).to receive(:delete)
  end

  describe '#send_audio_via_media_upload' do
    it 'uploads original file without invoking audio conversion service' do
      success_response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'messages' => [{ 'id' => 'wamid.123' }], 'error' => nil }
      )

      expect(Whatsapp::AudioConverterService).not_to receive(:convert_to_ogg_opus)
      expect(service).to receive(:upload_media_to_whatsapp).with(temp_file.path, 'audio/webm').and_return('media_123')
      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send(:send_audio_via_media_upload, '5511999999999', message, attachment)

      expect(File).to have_received(:delete).with(temp_file.path)
      expect(message.status).to be_nil
      expect(message.external_error).to be_nil
    end

    # EVO-1460 follow-up: handle_error and mark_audio_upload_failed used to write
    # message.status = :failed + save! directly, bypassing Wisper. They now route
    # through Messages::StatusUpdateService so :message_status_changed is published
    # for the EvoFlow listener (EVO-1240).
    it 'routes provider error to Messages::StatusUpdateService (handle_error funnel)' do
      service.instance_variable_set(:@message, message)

      failed_message_response = instance_double(
        HTTParty::Response,
        success?: false,
        parsed_response: { 'error' => { 'message' => 'Invalid audio payload' } },
        body: '{"error":{"message":"Invalid audio payload"}}'
      )

      expect(service).to receive(:upload_media_to_whatsapp).with(temp_file.path, 'audio/webm').and_return('media_123')
      allow(HTTParty).to receive(:post).and_return(failed_message_response)

      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      expect(Messages::StatusUpdateService).to receive(:new)
        .with(message, 'failed', 'Invalid audio payload')
        .and_return(status_service)

      result = service.send(:send_audio_via_media_upload, '5511999999999', message, attachment)

      expect(result).to be_nil
    end

    it 'routes audio upload failure to Messages::StatusUpdateService (mark_audio_upload_failed funnel)' do
      allow(service).to receive(:upload_media_to_whatsapp).and_raise(
        described_class::AudioUploadError,
        'WHATSAPP_CLOUD_AUDIO_UPLOAD_FAILED - WhatsApp API Error (131053) - Unsupported media type'
      )
      expect(HTTParty).not_to receive(:post)

      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      expect(Messages::StatusUpdateService).to receive(:new)
        .with(message, 'failed', a_string_including('WHATSAPP_CLOUD_AUDIO_UPLOAD_FAILED'))
        .and_return(status_service)

      result = service.send(:send_audio_via_media_upload, '5511999999999', message, attachment)

      expect(result).to be_nil
      expect(File).to have_received(:delete).with(temp_file.path)
    end

    it 'falls back mime type to application/octet-stream when blob content_type is absent' do
      nil_mime_blob = instance_double('ActiveStorage::Blob', content_type: nil)
      nil_mime_file = instance_double('AttachmentFile', blob: nil_mime_blob, filename: 'voice.bin')
      nil_mime_attachment = instance_double('Attachment', file: nil_mime_file)
      success_response = instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'messages' => [{ 'id' => 'wamid.123' }], 'error' => nil }
      )

      expect(service).to receive(:upload_media_to_whatsapp).with(temp_file.path, 'application/octet-stream').and_return('media_123')
      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send(:send_audio_via_media_upload, '5511999999999', message, nil_mime_attachment)
    end
  end

  describe '#upload_media_to_whatsapp' do
    it 'raises with explicit prefix when cloud api rejects media' do
      upload_file = Tempfile.new(['audio', '.webm'])
      upload_file.write('dummy audio data')
      upload_file.rewind

      failed_response = instance_double(
        HTTParty::Response,
        success?: false,
        code: 400,
        body: '{"error":{"code":131053,"message":"Unsupported media type"}}',
        parsed_response: {
          'error' => {
            'code' => 131053,
            'message' => 'Unsupported media type'
          }
        }
      )

      allow(HTTParty).to receive(:post).and_return(failed_response)

      expect do
        service.send(:upload_media_to_whatsapp, upload_file.path, 'audio/webm')
      end.to raise_error(StandardError, /WHATSAPP_CLOUD_AUDIO_UPLOAD_FAILED/)
    ensure
      upload_file.close!
    end
  end
end
