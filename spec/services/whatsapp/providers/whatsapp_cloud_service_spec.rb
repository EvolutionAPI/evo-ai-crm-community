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
  let(:temp_file) { instance_double(Tempfile, path: '/tmp/voice.webm', close!: nil) }
  let(:converted_path) { '/tmp/voice.ogg' }

  before do
    allow(service).to receive(:download_attachment_to_temp).and_return(temp_file)

    # Browser voice notes arrive as audio/webm; the service transcodes to
    # OGG/Opus before upload. Stub the converter so these specs don't shell out
    # to ffmpeg — the real transcode is exercised in the AudioConverterService spec.
    allow(Whatsapp::AudioConverterService).to receive(:convert_to_ogg_opus).and_return(converted_path)

    # the download is released via Tempfile#close!, the transcoded copy via FileUtils.rm_f
    allow(FileUtils).to receive(:rm_f)
  end

  describe '#send_audio_via_media_upload' do
    let(:success_response) do
      instance_double(
        HTTParty::Response,
        success?: true,
        parsed_response: { 'messages' => [{ 'id' => 'wamid.123' }], 'error' => nil }
      )
    end

    it 'transcodes a browser voice note (audio/webm) to ogg/opus before upload' do
      expect(Whatsapp::AudioConverterService).to receive(:convert_to_ogg_opus)
        .with(temp_file.path).and_return(converted_path)
      expect(service).to receive(:upload_media_to_whatsapp).with(converted_path, 'audio/ogg').and_return('media_123')
      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send(:send_audio_via_media_upload, '5511999999999', message, attachment)

      # both the original download and the transcoded copy are cleaned up
      expect(temp_file).to have_received(:close!)
      expect(FileUtils).to have_received(:rm_f).with(converted_path)
      expect(message.status).to be_nil
      expect(message.external_error).to be_nil
    end

    it 'transcodes when the blob has no content_type (application/octet-stream fallback)' do
      nil_mime_blob = instance_double('ActiveStorage::Blob', content_type: nil)
      nil_mime_file = instance_double('AttachmentFile', blob: nil_mime_blob, filename: 'voice.bin')
      nil_mime_attachment = instance_double('Attachment', file: nil_mime_file)

      expect(Whatsapp::AudioConverterService).to receive(:convert_to_ogg_opus)
        .with(temp_file.path).and_return(converted_path)
      expect(service).to receive(:upload_media_to_whatsapp).with(converted_path, 'audio/ogg').and_return('media_123')
      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send(:send_audio_via_media_upload, '5511999999999', message, nil_mime_attachment)

      expect(message.status).to be_nil
    end

    it 'passes audio already in an accepted format (audio/ogg) through without transcoding' do
      allow(blob).to receive(:content_type).and_return('audio/ogg')

      expect(Whatsapp::AudioConverterService).not_to receive(:convert_to_ogg_opus)
      expect(service).to receive(:upload_media_to_whatsapp).with(temp_file.path, 'audio/ogg').and_return('media_123')
      allow(HTTParty).to receive(:post).and_return(success_response)

      service.send(:send_audio_via_media_upload, '5511999999999', message, attachment)

      expect(message.status).to be_nil
    end

    it 'marks the message failed (without uploading) when transcoding fails' do
      allow(Whatsapp::AudioConverterService).to receive(:convert_to_ogg_opus).and_raise(
        Whatsapp::AudioConverterService::ConversionError, 'FFmpeg conversion failed: boom'
      )
      expect(service).not_to receive(:upload_media_to_whatsapp)

      status_service = instance_double(Messages::StatusUpdateService, perform: true)
      expect(Messages::StatusUpdateService).to receive(:new)
        .with(message, 'failed', a_string_including('WHATSAPP_CLOUD_AUDIO_TRANSCODE_FAILED'))
        .and_return(status_service)

      result = service.send(:send_audio_via_media_upload, '5511999999999', message, attachment)

      expect(result).to be_nil
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

      expect(service).to receive(:upload_media_to_whatsapp).with(converted_path, 'audio/ogg').and_return('media_123')
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
      expect(temp_file).to have_received(:close!)
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
            'code' => 131_053,
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

    it 'refuses to upload a file over the 16 MB limit instead of letting Meta reject it' do
      upload_file = Tempfile.new(['audio', '.ogg'])
      upload_file.write('x')
      upload_file.rewind
      allow(File).to receive(:size).and_call_original
      allow(File).to receive(:size).with(upload_file.path).and_return(described_class::WHATSAPP_MAX_MEDIA_BYTES + 1)

      expect(HTTParty).not_to receive(:post)

      expect do
        service.send(:upload_media_to_whatsapp, upload_file.path, 'audio/ogg')
      end.to raise_error(described_class::AudioUploadError, /over the .* byte limit/)
    ensure
      upload_file.close!
    end
  end
end
