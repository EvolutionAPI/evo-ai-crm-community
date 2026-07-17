# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EvolutionGo::HealthMonitorService do
  let(:observed_channel) do
    instance_double(Channel::Whatsapp, phone_number: '+5511999999999',
                                        inbox: instance_double(Inbox, name: 'Observed'),
                                        provider_config: { 'api_url' => 'https://go.example.com', 'instance_token' => 'observed-token' })
  end
  let(:notification_channel) do
    instance_double(Channel::Whatsapp, provider_config: { 'api_url' => 'https://go.example.com', 'instance_token' => 'notifier-token' })
  end
  let(:monitor) do
    instance_double(EvolutionGoHealthMonitor, observed_channel: observed_channel, notification_channel: notification_channel,
                                               recipient_number: '+5511888888888', failure_threshold: 2, recovery_threshold: 1,
                                               cooldown_minutes: 30, last_state: 'healthy', consecutive_failures: 0,
                                               consecutive_successes: 0, last_alerted_at: nil, last_error: nil)
  end

  before do
    allow(monitor).to receive(:save!)
    %i[last_checked_at= last_alerted_at=].each { |setter| allow(monitor).to receive(setter) }
    %i[consecutive_failures consecutive_successes last_error last_state].each do |attribute|
      allow(monitor).to receive("#{attribute}=") { |value| allow(monitor).to receive(attribute).and_return(value) }
    end
  end

  it 'waits for the failure threshold before sending a DOWN alert' do
    down = instance_double(HTTParty::Response, success?: true, parsed_response: { 'data' => { 'Connected' => false, 'LoggedIn' => false } })
    allow(HTTParty).to receive(:get).and_return(down)
    expect(HTTParty).not_to receive(:post)

    described_class.new(monitor).perform

    expect(monitor.consecutive_failures).to eq(1)
    expect(monitor.last_state).to eq('healthy')
  end

  it 'sends a DOWN alert when the threshold is reached' do
    allow(monitor).to receive(:consecutive_failures).and_return(1)
    down = instance_double(HTTParty::Response, success?: true, parsed_response: { 'data' => { 'Connected' => false, 'LoggedIn' => false } })
    sent = instance_double(HTTParty::Response, success?: true, code: 200)
    allow(HTTParty).to receive(:get).and_return(down)
    expect(HTTParty).to receive(:post).with('https://go.example.com/send/text', hash_including(headers: hash_including('apikey' => 'notifier-token'))).and_return(sent)

    described_class.new(monitor).perform

    expect(monitor.last_state).to eq('degraded')
  end

  it 'sends a recovery alert when the observed instance becomes healthy' do
    allow(monitor).to receive(:last_state).and_return('degraded')
    up = instance_double(HTTParty::Response, success?: true, parsed_response: { 'data' => { 'Connected' => true, 'LoggedIn' => true } })
    allow(HTTParty).to receive(:get).and_return(up)
    expect(HTTParty).to receive(:post).and_return(instance_double(HTTParty::Response, success?: true, code: 200))

    described_class.new(monitor).perform

    expect(monitor.last_state).to eq('healthy')
  end

  it 'does not send duplicate DOWN alerts within the cooldown period' do
    allow(monitor).to receive(:consecutive_failures).and_return(1)
    allow(monitor).to receive(:last_state).and_return('degraded')
    allow(monitor).to receive(:last_alerted_at).and_return(5.minutes.ago)
    down = instance_double(HTTParty::Response, success?: true, parsed_response: { 'data' => { 'Connected' => false, 'LoggedIn' => false } })
    allow(HTTParty).to receive(:get).and_return(down)
    expect(HTTParty).not_to receive(:post)

    described_class.new(monitor).perform

    expect(monitor.last_state).to eq('degraded')
  end
end
