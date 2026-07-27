# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Products::UrlSafety do
  describe '.private_ip?' do
    it 'accepts a public IPv4 address' do
      expect(described_class.private_ip?('93.184.216.34')).to be(false)
    end

    it 'accepts a public IPv6 address' do
      expect(described_class.private_ip?('2606:2800:220:1:248:1893:25c8:1946')).to be(false)
    end

    %w[
      127.0.0.1 10.1.2.3 172.16.0.9 192.168.1.10 169.254.169.254
      100.64.0.1 0.0.0.0 198.18.0.5 224.0.0.1 240.0.0.1
    ].each do |addr|
      it "refuses the private/reserved address #{addr}" do
        expect(described_class.private_ip?(addr)).to be(true)
      end
    end

    %w[::1 fc00::1 fe80::1 ff02::1].each do |addr|
      it "refuses the private/reserved IPv6 address #{addr}" do
        expect(described_class.private_ip?(addr)).to be(true)
      end
    end

    # EVO-2226: IPAddr#include? never matches across families, so a mapped address
    # used to slip past every IPv4 range in the list.
    it 'refuses an IPv4-mapped IPv6 address pointing at link-local metadata' do
      expect(described_class.private_ip?('::ffff:169.254.169.254')).to be(true)
    end

    it 'refuses an IPv4-mapped IPv6 address pointing at loopback' do
      expect(described_class.private_ip?('::ffff:127.0.0.1')).to be(true)
    end

    it 'refuses NAT64-embedded IPv4' do
      expect(described_class.private_ip?('64:ff9b::a9fe:a9fe')).to be(true)
    end

    it 'refuses 6to4-embedded IPv4' do
      expect(described_class.private_ip?('2002:a9fe:a9fe::1')).to be(true)
    end

    it 'treats an unparseable address as unsafe' do
      expect(described_class.private_ip?('not-an-ip')).to be(true)
    end
  end

  describe '.public_host?' do
    it 'is true when every resolved address is public' do
      allow(Resolv).to receive(:getaddresses).and_return(['93.184.216.34'])
      expect(described_class.public_host?('cdn.example.com')).to be(true)
    end

    it 'is false when ANY resolved address is private (mixed answer)' do
      allow(Resolv).to receive(:getaddresses).and_return(['93.184.216.34', '127.0.0.1'])
      expect(described_class.public_host?('rebind.example.com')).to be(false)
    end

    it 'is false when the host does not resolve' do
      allow(Resolv).to receive(:getaddresses).and_return([])
      expect(described_class.public_host?('nope.example.com')).to be(false)
    end

    it 'is false for a blank host' do
      expect(described_class.public_host?(nil)).to be(false)
      expect(described_class.public_host?('')).to be(false)
    end
  end
end
