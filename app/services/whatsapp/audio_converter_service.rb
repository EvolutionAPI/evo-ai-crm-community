# frozen_string_literal: true

require 'English'
require 'shellwords'

module Whatsapp
  class AudioConverterService
    class ConversionError < StandardError; end

    # Convert audio file to OGG format with Opus codec
    # @param input_path [String] Path to the input audio file
    # @return [String] Path to the converted OGG file
    def self.convert_to_ogg_opus(input_path)
      raise ConversionError, 'Input file does not exist' unless File.exist?(input_path)

      output_path = input_path.sub(File.extname(input_path), '.ogg')

      # Build FFmpeg command for OGG/Opus conversion
      # Based on WhatsApp's recommended audio format:
      # - Codec: Opus
      # - Container: OGG
      # - Sample rate: 48000 Hz
      # - Channels: 1 (mono)
      # - Bitrate: 128k
      command = build_ffmpeg_command(input_path, output_path)

      Rails.logger.info "Converting audio: #{input_path} -> #{output_path}"
      Rails.logger.debug { "FFmpeg command: #{command}" }

      # Execute FFmpeg conversion
      output = `#{command} 2>&1`
      status = $CHILD_STATUS

      unless status.success?
        Rails.logger.error "FFmpeg conversion failed: #{output}"
        raise ConversionError, "FFmpeg conversion failed: #{output}"
      end

      Rails.logger.info "Audio converted successfully: #{output_path}"
      output_path
    rescue StandardError => e
      Rails.logger.error "Audio conversion error: #{e.message}"
      raise ConversionError, e.message
    end

    # Build FFmpeg command with proper options for WhatsApp voice messages
    def self.build_ffmpeg_command(input_path, output_path)
      # Escape file paths for shell
      input_escaped = Shellwords.escape(input_path)
      output_escaped = Shellwords.escape(output_path)

      # FFmpeg options optimized for WhatsApp voice messages
      # -y: overwrite output file if exists
      # -i: input file
      # -vn: disable video (audio only)
      # -c:a libopus: use Opus audio codec
      # -b:a 128k: audio bitrate 128 kbps
      # -ar 48000: sample rate 48000 Hz
      # -ac 1: mono audio (1 channel)
      # -application voip: optimize for voice
      # -avoid_negative_ts make_zero: handle timestamp issues
      [
        'ffmpeg',
        '-y',
        '-i', input_escaped,
        '-vn',
        '-c:a', 'libopus',
        '-b:a', '128k',
        '-ar', '48000',
        '-ac', '1',
        '-application', 'voip',
        '-avoid_negative_ts', 'make_zero',
        output_escaped
      ].join(' ')
    end
  end
end
