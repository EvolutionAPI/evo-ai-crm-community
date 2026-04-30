# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Avatar::AvatarFromUrlJob do
  let(:avatarable) { instance_double(Contact, avatar: avatar_double) }
  let(:avatar_double) { instance_double(ActiveStorage::Attached::One) }

  before do
    allow(avatarable).to receive(:respond_to?).with(:avatar).and_return(true)
  end

  describe 'URL safety' do
    it 'blocks non-http(s) schemes' do
      expect(Down).not_to receive(:download)

      described_class.new.perform(avatarable, 'file:///etc/passwd')
    end

    it 'blocks loopback hosts' do
      expect(Down).not_to receive(:download)

      described_class.new.perform(avatarable, 'http://127.0.0.1/avatar.jpg')
    end

    it 'blocks AWS link-local metadata service' do
      expect(Down).not_to receive(:download)

      described_class.new.perform(avatarable, 'http://169.254.169.254/latest/meta-data/iam/security-credentials/')
    end

    it 'blocks RFC1918 private addresses' do
      expect(Down).not_to receive(:download)

      described_class.new.perform(avatarable, 'http://10.0.0.5/avatar.jpg')
    end

    it 'blocks hostnames that resolve to private IPs' do
      allow(Resolv).to receive(:getaddresses).with('internal.evil').and_return(['192.168.1.10'])

      expect(Down).not_to receive(:download)

      described_class.new.perform(avatarable, 'https://internal.evil/avatar.jpg')
    end

    it 'allows public hostnames and disables redirects on Down' do
      allow(Resolv).to receive(:getaddresses).with('cdn.example.com').and_return(['8.8.8.8'])

      file = double('Down::ChunkedIO', original_filename: 'avatar.jpg', content_type: 'image/jpeg')
      allow(Down).to receive(:download).with(
        'https://cdn.example.com/avatar.jpg',
        max_size: 15 * 1024 * 1024,
        max_redirects: 0
      ).and_return(file)

      expect(avatar_double).to receive(:attach).with(io: file, filename: 'avatar.jpg', content_type: 'image/jpeg')

      described_class.new.perform(avatarable, 'https://cdn.example.com/avatar.jpg')
    end

    it 'blocks blank or malformed URLs' do
      expect(Down).not_to receive(:download)

      described_class.new.perform(avatarable, '')
      described_class.new.perform(avatarable, 'not a url at all')
    end
  end
end
