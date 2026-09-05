# frozen_string_literal: true

require 'rails_helper'

# transcription resolves its credential from the registry,
# and the toggle stops meaning "has a key".
RSpec.describe Messages::AudioTranscriptionService do
  let(:attached_file) { instance_double(ActiveStorage::Attached::One, attached?: true) }
  let(:attachment) { instance_double(Attachment, file: attached_file) }
  let(:service) { described_class.new(attachment: attachment) }

  describe '#transcription_enabled? separates the toggle from the credential (AC4)' do
    it 'stays enabled with the global toggle on even when no credential resolves' do
      allow(GlobalConfigService).to receive(:load)
        .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(true)
      # No credential anywhere: the feature is still ON, it just cannot run.
      allow(Ai::CredentialResolver).to receive(:resolve_key).and_return(nil)

      expect(service.send(:transcription_enabled?)).to be(true)
    end

    it 'is disabled when the global toggle is off, credential or not' do
      allow(GlobalConfigService).to receive(:load)
        .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(false)
      allow(Ai::CredentialResolver).to receive(:resolve_key).and_return('sk-usable')

      expect(service.send(:transcription_enabled?)).to be(false)
    end

    it 'accepts string values for the global toggle' do
      %w[true 1 yes on].each do |truthy|
        allow(GlobalConfigService).to receive(:load)
          .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(truthy)

        expect(service.send(:transcription_enabled?)).to be(true)
      end

      %w[false 0 no off].each do |falsy|
        allow(GlobalConfigService).to receive(:load)
          .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(falsy)

        expect(service.send(:transcription_enabled?)).to be(false)
      end
    end

    context 'when the global toggle is unset and the hook decides' do
      before do
        allow(GlobalConfigService).to receive(:load)
          .with('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil).and_return(nil)
      end

      it 'is enabled by the hook toggle alone, with no api_key in settings' do
        hook = instance_double(Integrations::Hook, enabled?: true,
                                                   settings: { 'enable_audio_transcription' => true })
        allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(hook)

        # Before this story the same settings without 'api_key' returned false,
        # so a missing credential looked exactly like a disabled feature.
        expect(service.send(:transcription_enabled?)).to be(true)
      end

      it 'is disabled when the hook toggle is off' do
        hook = instance_double(Integrations::Hook, enabled?: true,
                                                   settings: { 'enable_audio_transcription' => false })
        allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(hook)

        expect(service.send(:transcription_enabled?)).to be(false)
      end

      it 'is disabled when there is no hook at all' do
        allow(Integrations::Hook).to receive(:find_by).with(app_id: 'openai').and_return(nil)

        expect(service.send(:transcription_enabled?)).to be(false)
      end
    end
  end

  describe '#get_openai_api_key delegates to the resolver (AC1)' do
    it 'asks the resolver for the audio_transcription consumer' do
      expect(Ai::CredentialResolver).to receive(:resolve_key)
        .with(for_consumer: :audio_transcription).and_return('sk-from-registry')

      expect(service.send(:get_openai_api_key)).to eq('sk-from-registry')
    end

    it 'does not read GlobalConfigService directly any more' do
      # The duplicated precedence chain was deleted, not adapted: it lives in
      # Ai::CredentialResolver, and reading it here would fork the rule again.
      allow(Ai::CredentialResolver).to receive(:resolve_key).and_return('sk-from-registry')
      expect(GlobalConfigService).not_to receive(:load).with('OPENAI_API_SECRET', nil)

      service.send(:get_openai_api_key)
    end
  end

  describe '#transcribe_audio without a credential (AC5)' do
    it 'does not call Whisper and records the reason' do
      allow(Ai::CredentialResolver).to receive(:resolve_key).and_return(nil)
      allow(Rails.logger).to receive(:warn)

      expect(service).not_to receive(:call_openai_whisper_api)
      expect(service.send(:transcribe_audio)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/no AI credential resolved/)
    end
  end
end
