class Messages::AudioTranscriptionService
  include Events::Types
  pattr_initialize [:attachment!]

  def perform
    Rails.logger.info "AudioTranscriptionService: Starting for attachment #{attachment.id}"

    unless attachment.audio?
      Rails.logger.warn "AudioTranscriptionService: Attachment #{attachment.id} is not audio"
      return { error: 'Attachment is not audio' }
    end

    if attachment.meta&.[]('transcribed_text').present?
      Rails.logger.info "AudioTranscriptionService: Transcription already exists for attachment #{attachment.id}"
      return { error: 'Transcription already exists' }
    end

    unless transcription_enabled?
      Rails.logger.warn "AudioTranscriptionService: Transcription not enabled"
      return { error: 'Transcription not enabled' }
    end

    Rails.logger.info "AudioTranscriptionService: Transcription enabled, starting transcription..."
    transcribed_text = transcribe_audio

    unless transcribed_text.present?
      Rails.logger.warn "AudioTranscriptionService: Transcription returned empty result for attachment #{attachment.id}"
      return { error: 'Transcription failed' }
    end

    Rails.logger.info "AudioTranscriptionService: Transcription successful, saving to attachment #{attachment.id}"

    # Save transcription to attachment meta
    attachment.meta ||= {}
    attachment.meta['transcribed_text'] = transcribed_text
    attachment.save!

    # Reload attachment and message to ensure fresh data for broadcast
    message = attachment.message
    attachment.reload
    message.reload

    # Clear attachments association cache to ensure fresh data when push_event_data is called
    # This forces Rails to reload attachments from database when push_event_data accesses them
    message.association(:attachments).reset

    # Broadcast message update to frontend so transcription appears
    Rails.configuration.dispatcher.dispatch(
      MESSAGE_UPDATED,
      Time.zone.now,
      message: message,
      previous_changes: { 'attachments' => [attachment.id] }
    )

    Rails.logger.info "AudioTranscriptionService: Transcription saved successfully for attachment #{attachment.id}"
    { success: true, transcribed_text: transcribed_text }
  rescue StandardError => e
    Rails.logger.error "AudioTranscriptionService: Error for attachment #{attachment.id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { error: e.message }
  end

  private

  def transcription_enabled?
    # Priority 1: Check global configuration
    # If global config is explicitly set (not nil), use it exclusively
    global_enabled = GlobalConfigService.load('OPENAI_ENABLE_AUDIO_TRANSCRIPTION', nil)
    unless global_enabled.nil?
      # Convert to boolean - handle both boolean and string values
      # GlobalConfig should typecast boolean values, but we handle both cases
      enabled = if global_enabled.is_a?(TrueClass) || global_enabled.is_a?(FalseClass)
                  global_enabled
                else
                  # Handle string values
                  case global_enabled.to_s.downcase
                  when 'true', '1', 'yes', 'on'
                    true
                  when 'false', '0', 'no', 'off', ''
                    false
                  else
                    false
                  end
                end

      Rails.logger.info "AudioTranscriptionService: Global config value: #{global_enabled.inspect} (#{global_enabled.class}), converted to: #{enabled.inspect}"

      Rails.logger.info "AudioTranscriptionService: Transcription #{enabled ? 'enabled' : 'disabled'} via global config"
      return enabled
    end

    # Priority 2: Check OpenAI integration hook settings
    openai_hook = Integrations::Hook.find_by(app_id: 'openai')
    return false unless openai_hook&.enabled?

    openai_hook.settings&.[]('enable_audio_transcription') == true
  end

  def transcribe_audio
    return nil unless attachment.file.attached?

    api_key = get_openai_api_key
    if api_key.blank?
      # The toggle is on but no credential resolves. Saying so explicitly beats
      # behaving like the feature was switched off, which is what hid the
      # missing credential from the user before.
      Rails.logger.warn(
        'AudioTranscriptionService: transcription is enabled but no AI credential resolved ' \
        '(register one under Settings > AI Credentials)'
      )
      return nil
    end

    # Download audio file
    audio_file = download_audio_file
    return nil unless audio_file

    # Call OpenAI Whisper API
    response = call_openai_whisper_api(api_key, audio_file)

    # Clean up temp file
    File.delete(audio_file.path) if File.exist?(audio_file.path)

    response&.dig('text')
  rescue StandardError => e
    Rails.logger.error "OpenAI Whisper API error: #{e.message}"
    nil
  end

  # Whisper is a different endpoint from chat/completions, but the credential is
  # the same one every AI feature resolves. The precedence used to be copied
  # here; it now lives in Ai::CredentialResolver, its single owner.
  def get_openai_api_key
    Ai::CredentialResolver.resolve_key(for_consumer: :audio_transcription)
  end

  def download_audio_file
    return nil unless attachment.file.attached?

    # Retry with exponential backoff to handle race condition where file
    # might not be fully uploaded to S3 yet
    max_retries = 3
    retry_delay = 1 # seconds

    max_retries.times do |attempt|
      begin
        # Create temp file with valid extension
        file_extension = attachment.extension.presence || 'ogg'
        temp_file = Tempfile.new(['audio', ".#{file_extension}"])
        temp_file.binmode

        # Download from ActiveStorage
        attachment.file.download do |chunk|
          temp_file.write(chunk)
        end

        temp_file.rewind
        Rails.logger.info "AudioTranscriptionService: Successfully downloaded audio file (attempt #{attempt + 1})"
        return temp_file
      rescue ActiveStorage::FileNotFoundError => e
        if attempt < max_retries - 1
          wait_time = retry_delay * (2 ** attempt)
          Rails.logger.warn "AudioTranscriptionService: File not found, retrying in #{wait_time}s (attempt #{attempt + 1}/#{max_retries})"
          sleep(wait_time)
        else
          Rails.logger.error "AudioTranscriptionService: Error downloading audio file after #{max_retries} attempts: #{e.message}"
          return nil
        end
      rescue StandardError => e
        Rails.logger.error "AudioTranscriptionService: Error downloading audio file: #{e.message}"
        return nil
      end
    end

    nil
  end

  def call_openai_whisper_api(api_key, audio_file)
    require 'net/http'
    require 'uri'

    # Use GlobalConfigService for API URL (same pattern as OpenaiBaseService)
    base_url = GlobalConfigService.load('OPENAI_API_URL', 'https://api.openai.com/v1')
    transcription_url = "#{base_url}/audio/transcriptions"

    uri = URI(transcription_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri.path)
    request['Authorization'] = "Bearer #{api_key}"

    # Ensure we have a valid extension (default to 'ogg' for audio files)
    file_extension = attachment.extension.presence || 'ogg'
    filename = "audio.#{file_extension}"

    form_data = [
      ['file', audio_file, { filename: filename }],
      ['model', 'whisper-1']
    ]

    # Only add language if detect_language returns a non-nil value
    detected_language = detect_language
    form_data << ['language', detected_language] if detected_language.present?

    request.set_form(form_data, 'multipart/form-data')

    Rails.logger.info "OpenAI Whisper API request to #{transcription_url} for attachment #{attachment.id}"
    response = http.request(request)
    Rails.logger.info "OpenAI Whisper API response: #{response.code} - #{response.body[0..200]}"

    if response.code == '200'
      JSON.parse(response.body)
    else
      Rails.logger.error "OpenAI Whisper API error: #{response.code} - #{response.body}"
      nil
    end
  rescue StandardError => e
    Rails.logger.error "OpenAI Whisper API request error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    nil
  end

  def detect_language
    # Try to detect language from global locale config
    locale = GlobalConfigService.load('DEFAULT_LOCALE', nil)
    return 'pt' if locale&.start_with?('pt')
    return 'es' if locale&.start_with?('es')
    return 'fr' if locale&.start_with?('fr')
    return 'de' if locale&.start_with?('de')
    return 'it' if locale&.start_with?('it')

    # Default to auto-detect
    nil
  end
end

