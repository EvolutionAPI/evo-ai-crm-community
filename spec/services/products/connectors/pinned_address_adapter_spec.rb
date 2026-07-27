# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Products::Connectors::PinnedAddressAdapter do
  def connection_for(options)
    described_class.call(URI.parse('https://shop.example.com/wp-json/wc/v3/products'),
                         HTTParty::ConnectionAdapter::OPTION_DEFAULTS.merge(options))
  end

  # Without the pin the client resolves the host a second time, so a TTL-0 record can
  # answer public to the SSRF guard and internal to the connect (DNS rebinding).
  it 'dials the vetted address' do
    expect(connection_for(pinned_ip: '93.184.216.34').ipaddr).to eq('93.184.216.34')
  end

  # Net::HTTP uses @address (not the pinned ip) for the Host header, SNI and
  # post_connection_check, so pinning must not weaken certificate validation.
  it 'keeps the hostname for Host, SNI and certificate verification' do
    connection = connection_for(pinned_ip: '93.184.216.34')

    expect(connection.address).to eq('shop.example.com')
    expect(connection.use_ssl?).to be(true)
  end

  it 'leaves the connection alone when no address was pinned' do
    expect(connection_for({}).ipaddr).to be_nil
  end
end
