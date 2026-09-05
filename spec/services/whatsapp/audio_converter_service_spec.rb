# frozen_string_literal: true

require 'rails_helper'

# Functional spec: shells out to the real ffmpeg (shipped in the image) to prove
# a browser voice note (WebM/Opus) is transcoded to the OGG/Opus format WhatsApp
# Cloud accepts.
RSpec.describe Whatsapp::AudioConverterService do
  # The transcode fix depends on ffmpeg/ffprobe being in the image
  # (docker/Dockerfile). Assert it instead of skipping the examples below, so a
  # build that drops them fails here rather than silently in production.
  it 'runs on an image that ships ffmpeg and ffprobe' do
    expect(system('ffmpeg -version > /dev/null 2>&1')).to be(true)
    expect(system('ffprobe -version > /dev/null 2>&1')).to be(true)
  end

  def record_webm_opus(path)
    # what the browser MediaRecorder produces: Opus audio in a WebM container
    system(
      'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
      '-i', 'sine=frequency=440:duration=1', '-c:a', 'libopus', '-f', 'webm', path
    )
  end

  describe '.convert_to_ogg_opus' do
    it 'raises ConversionError when the input file does not exist' do
      expect { described_class.convert_to_ogg_opus('/tmp/does-not-exist-xyz.webm') }
        .to raise_error(described_class::ConversionError, /does not exist/)
    end

    it 'transcodes a real WebM/Opus voice note to a non-empty OGG/Opus file' do
      webm = Rails.root.join('tmp', "wa_in_#{SecureRandom.hex(4)}.webm").to_s
      ogg = webm.sub(/\.webm\z/, '.ogg')
      record_webm_opus(webm)

      out = described_class.convert_to_ogg_opus(webm)

      expect(out).to eq(ogg)
      expect(File.exist?(out)).to be(true)
      expect(File.size(out)).to be > 0

      codec = `ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 #{out}`.strip
      expect(codec).to eq('opus')
    ensure
      [webm, ogg].each { |f| File.delete(f) if f && File.exist?(f) }
    end

    it 'appends .ogg when the input has no extension instead of prepending it' do
      input = Rails.root.join('tmp', "wa_in_#{SecureRandom.hex(4)}").to_s
      ogg = "#{input}.ogg"
      record_webm_opus(input)

      expect(described_class.convert_to_ogg_opus(input)).to eq(ogg)
      expect(File.exist?(ogg)).to be(true)
    ensure
      [input, ogg].each { |f| File.delete(f) if f && File.exist?(f) }
    end

    it 'removes the partial output file when the conversion fails' do
      webm = Rails.root.join('tmp', "wa_in_#{SecureRandom.hex(4)}.webm").to_s
      ogg = webm.sub(/\.webm\z/, '.ogg')
      File.write(webm, 'not actually audio')
      File.write(ogg, 'partial output')

      expect { described_class.convert_to_ogg_opus(webm) }
        .to raise_error(described_class::ConversionError)
      expect(File.exist?(ogg)).to be(false)
    ensure
      [webm, ogg].each { |f| File.delete(f) if f && File.exist?(f) }
    end
  end

  describe '.audio_codec' do
    it 'reads the codec of an OGG/Opus file' do
      webm = Rails.root.join('tmp', "wa_in_#{SecureRandom.hex(4)}.webm").to_s
      record_webm_opus(webm)
      ogg = described_class.convert_to_ogg_opus(webm)

      expect(described_class.audio_codec(ogg)).to eq('opus')
    ensure
      [webm, ogg].each { |f| File.delete(f) if f && File.exist?(f) }
    end

    it 'reads the codec of an OGG carrying Vorbis (which WhatsApp rejects)' do
      ogg = Rails.root.join('tmp', "wa_in_#{SecureRandom.hex(4)}.ogg").to_s
      system(
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
        '-i', 'sine=frequency=440:duration=1', '-c:a', 'libvorbis', ogg
      )

      expect(described_class.audio_codec(ogg)).to eq('vorbis')
    ensure
      File.delete(ogg) if ogg && File.exist?(ogg)
    end

    it 'returns nil instead of raising when the file cannot be probed' do
      garbage = Rails.root.join('tmp', "wa_in_#{SecureRandom.hex(4)}.ogg").to_s
      File.write(garbage, 'not actually audio')

      expect(described_class.audio_codec(garbage)).to be_nil
    ensure
      File.delete(garbage) if garbage && File.exist?(garbage)
    end
  end

  describe '.run_with_timeout' do
    it 'kills the subprocess and raises once it outlives the timeout' do
      stub_const("#{described_class}::FFMPEG_TIMEOUT_SECONDS", 1)

      expect { described_class.run_with_timeout(['sleep', '30']) }
        .to raise_error(described_class::ConversionError, /timed out after 1s/)
    end
  end

  describe '.build_ffmpeg_command' do
    it 'returns argv (no shell) so paths need no escaping' do
      command = described_class.build_ffmpeg_command('/tmp/a b.webm', '/tmp/a b.ogg')

      expect(command).to be_an(Array)
      expect(command.first).to eq('ffmpeg')
      expect(command).to include('-nostdin', '/tmp/a b.webm', '/tmp/a b.ogg')
    end
  end
end
