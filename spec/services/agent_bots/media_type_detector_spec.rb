# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AgentBots::MediaTypeDetector do
  describe '.detect' do
    {
      'https://x/v.mp4' => 'video',
      'https://x/v.MP4' => 'video',
      'https://x/v.mp4?token=abc' => 'video', # querystring ignored
      'https://x/v.mov#t=10' => 'video',
      'https://x/pic.jpg' => 'image',
      'https://x/pic.png' => 'image',
      'https://x/song.mp3' => 'audio',
      'https://x/doc.pdf' => 'document',
      'https://x/sheet.xlsx' => 'document',
      'https://site.com/page' => 'text', # no extension
      'https://site.com/p.html' => 'text', # not media
      '' => 'text',
      nil => 'text'
    }.each do |url, expected|
      it "classifies #{url.inspect} as #{expected}" do
        expect(described_class.detect(url)).to eq(expected)
      end
    end
  end

  describe '.attachment_file_type' do
    it 'maps document to file (Attachment has no :document enum)' do
      expect(described_class.attachment_file_type('document')).to eq('file')
    end

    it 'passes through image/audio/video' do
      expect(described_class.attachment_file_type('video')).to eq('video')
      expect(described_class.attachment_file_type('image')).to eq('image')
      expect(described_class.attachment_file_type('audio')).to eq('audio')
    end
  end
end
