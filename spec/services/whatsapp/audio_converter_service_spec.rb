# frozen_string_literal: true

require 'rails_helper'

# Functional spec: shells out to the real ffmpeg (shipped in the image) to prove
# a browser voice note (WebM/Opus) is transcoded to the OGG/Opus format WhatsApp
# Cloud accepts. The example self-skips where ffmpeg is unavailable.
RSpec.describe Whatsapp::AudioConverterService do
  describe '.convert_to_ogg_opus' do
    it 'raises ConversionError when the input file does not exist' do
      expect { described_class.convert_to_ogg_opus('/tmp/does-not-exist-xyz.webm') }
        .to raise_error(described_class::ConversionError, /does not exist/)
    end

    it 'transcodes a real WebM/Opus voice note to a non-empty OGG/Opus file' do
      skip 'ffmpeg not available' unless system('ffmpeg -version > /dev/null 2>&1')

      webm = Rails.root.join('tmp', "wa_in_#{SecureRandom.hex(4)}.webm").to_s
      ogg = webm.sub(/\.webm\z/, '.ogg')
      # what the browser MediaRecorder produces: Opus audio in a WebM container
      system(
        'ffmpeg -y -hide_banner -loglevel error -f lavfi ' \
        "-i sine=frequency=440:duration=1 -c:a libopus -f webm #{webm}"
      )

      out = described_class.convert_to_ogg_opus(webm)

      expect(out).to eq(ogg)
      expect(File.exist?(out)).to be(true)
      expect(File.size(out)).to be > 0

      codec = `ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 #{out}`.strip
      expect(codec).to eq('opus')
    ensure
      [webm, ogg].each { |f| File.delete(f) if f && File.exist?(f) }
    end
  end
end
