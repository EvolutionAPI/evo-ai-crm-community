require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Mail::BmsProvider do
  let(:provider) { described_class.new({}) }
  let(:mail) do
    message = Mail.new
    message.from = 'ACME <no-reply@acme.test>'
    message.to = 'buyer@x.test'
    message.subject = 'Welcome'
    message.body = '<p>hi</p>'
    message
  end

  before do
    allow(GlobalConfigService).to receive(:load).with('BMS_API_SECRET', nil).and_return('mk_test')
    allow(GlobalConfigService).to receive(:load).with('BMS_IPPOOL', 'default').and_return('default')
  end

  def stub_bms(base)
    stub_request(:post, "#{base}/services/send-email")
      .to_return(status: 200, body: '{"ok":true}', headers: { 'Content-Type' => 'application/json' })
  end

  def configure_url(value)
    allow(GlobalConfigService).to receive(:load).with('BMS_API_URL', nil).and_return(value)
  end

  it 'posts to the instance configured in BMS_API_URL with the api-key header' do
    configure_url('https://bms-app.example.test')
    stub = stub_bms('https://bms-app.example.test')

    provider.deliver!(mail)

    expect(stub.with(headers: { 'api-key' => 'mk_test' })).to have_been_requested
  end

  it 'keeps a configured /api prefix as-is, stripping only the trailing slash' do
    # The evofoundation instance REQUIRES the /api prefix (405 without it);
    # stripping it regressed prod, so the config value decides.
    configure_url('https://bms-app.example.test/api/')
    stub = stub_bms('https://bms-app.example.test/api')

    provider.deliver!(mail)

    expect(stub).to have_been_requested
  end

  it 'posts as-is when the configured base has no /api (the common prod shape)' do
    configure_url('https://bms-app.example.test')
    stub = stub_bms('https://bms-app.example.test')

    provider.deliver!(mail)

    expect(stub).to have_been_requested
  end

  it 'keeps an explicit port on the configured base' do
    configure_url('https://bms-app.example.test:8443')
    stub = stub_bms('https://bms-app.example.test:8443')

    provider.deliver!(mail)

    expect(stub).to have_been_requested
  end

  it 'falls back to the legacy host when the config is empty' do
    configure_url(nil)
    stub = stub_bms('https://bms-api.bri.us')

    provider.deliver!(mail)

    expect(stub).to have_been_requested
  end

  it 'raises DeliveryError when the configured instance rejects the key' do
    configure_url('https://bms-app.example.test')
    stub_request(:post, 'https://bms-app.example.test/services/send-email')
      .to_return(status: 401, body: '{"message":"Invalid API key"}')

    expect { provider.deliver!(mail) }.to raise_error(Mail::BmsProvider::DeliveryError, /401/)
  end
end
