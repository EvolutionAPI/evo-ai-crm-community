# frozen_string_literal: true

require 'open3'

module Whatsapp
  class AudioConverterService
    class ConversionError < StandardError; end

    # Hard ceiling for the ffmpeg subprocess. Transcoding a voice note takes
    # well under a second; anything past this is a hung or pathological input,
    # and it runs inline on the Sidekiq thread that sends the message.
    FFMPEG_TIMEOUT_SECONDS = 30

    # Convert audio file to OGG format with Opus codec
    # @param input_path [String] Path to the input audio file
    # @return [String] Path to the converted OGG file
    def self.convert_to_ogg_opus(input_path)
      raise ConversionError, 'Input file does not exist' unless File.exist?(input_path)

      output_path = ogg_output_path(input_path)

      # Build FFmpeg command for OGG/Opus conversion
      # Based on WhatsApp's recommended audio format:
      # - Codec: Opus
      # - Container: OGG
      # - Sample rate: 48000 Hz
      # - Channels: 1 (mono)
      # - Bitrate: 128k
      command = build_ffmpeg_command(input_path, output_path)

      Rails.logger.info "Converting audio: #{input_path} -> #{output_path}"
      Rails.logger.debug { "FFmpeg command: #{command.join(' ')}" }

      # Execute FFmpeg conversion
      output, status = run_with_timeout(command)

      unless status.success?
        Rails.logger.error "FFmpeg conversion failed: #{output}"
        raise ConversionError, "FFmpeg conversion failed: #{output}"
      end

      Rails.logger.info "Audio converted successfully: #{output_path}"
      output_path
    rescue StandardError => e
      # ffmpeg opens the output file before it finishes decoding, so a failure
      # can leave a partial .ogg behind. The caller only cleans up paths this
      # method returned, so drop it here.
      FileUtils.rm_f(output_path) if output_path
      Rails.logger.error "Audio conversion error: #{e.message}"
      raise ConversionError, e.message
    end

    # Swap the extension for .ogg. Not String#sub: File.extname returns "" for
    # a file with no extension, and sub("") matches at position 0, which would
    # prepend ".ogg" to the path instead of appending it.
    def self.ogg_output_path(input_path)
      "#{input_path.delete_suffix(File.extname(input_path))}.ogg"
    end

    # Codec of the first audio stream, used to tell an OGG/Opus apart from an
    # OGG carrying anything else. Never raises: a probe we cannot run must not
    # fail the send, it falls back to the caller's default.
    # @return [String, nil] codec name, or nil when it cannot be read
    def self.audio_codec(input_path)
      command = [
        'ffprobe', '-v', 'error', '-select_streams', 'a:0',
        '-show_entries', 'stream=codec_name', '-of', 'csv=p=0', input_path
      ]
      output, status = run_with_timeout(command)
      return nil unless status.success?

      codec = output.strip
      codec.empty? ? nil : codec
    rescue StandardError => e
      Rails.logger.warn "Could not probe audio codec of #{input_path}: #{e.message}"
      nil
    end

    # Run ffmpeg/ffprobe without a shell and kill the process group if it
    # outlives FFMPEG_TIMEOUT_SECONDS, so a hung encode cannot pin the worker.
    # @return [Array(String, Process::Status)] combined output and exit status
    def self.run_with_timeout(command)
      Open3.popen2e(*command, pgroup: true) do |stdin, out_err, wait_thr|
        stdin.close

        # Drain stdout/stderr concurrently: ffmpeg deadlocks if the pipe buffer
        # fills while we are waiting on the process.
        reader = Thread.new { out_err.read }
        reader.report_on_exception = false

        unless wait_thr.join(FFMPEG_TIMEOUT_SECONDS)
          terminate_process_group(wait_thr.pid)
          reader.join(1)
          raise ConversionError, "#{command.first} timed out after #{FFMPEG_TIMEOUT_SECONDS}s"
        end

        [reader.value.to_s, wait_thr.value]
      end
    end

    def self.terminate_process_group(pid)
      Process.kill('KILL', -pid)
    rescue Errno::ESRCH
      # already gone
    end

    # Build FFmpeg command with proper options for WhatsApp voice messages
    # @return [Array<String>] argv, executed without a shell
    def self.build_ffmpeg_command(input_path, output_path)
      # FFmpeg options optimized for WhatsApp voice messages
      # -y: overwrite output file if exists
      # -nostdin: never touch the worker's stdin
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
        '-nostdin',
        '-i', input_path,
        '-vn',
        '-c:a', 'libopus',
        '-b:a', '128k',
        '-ar', '48000',
        '-ac', '1',
        '-application', 'voip',
        '-avoid_negative_ts', 'make_zero',
        output_path
      ]
    end
  end
end
