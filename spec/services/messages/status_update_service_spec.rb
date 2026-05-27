# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messages::StatusUpdateService do
  let(:message) do
    instance_double(
      Message,
      id: 1,
      status: 'sent',
      content_attributes: {},
      read?: false,
      failed?: false,
      delivered?: false,
      update!: true
    )
  end

  before do
    # avoid touching the global Wisper subscribers; we attach a temporary
    # collector to the service instance for the duration of the example.
    allow(Message).to receive(:statuses).and_return('sent' => 0, 'delivered' => 1, 'read' => 2, 'failed' => 3)
  end

  # Local helper: attach an ad-hoc Wisper collector to the service instance,
  # call #perform once, and return [result, events].
  def perform_and_capture(service)
    collector = []
    listener = Class.new do
      define_method(:message_status_changed) { |data| collector << data }
    end.new
    service.subscribe(listener)
    [service.perform, collector]
  end

  it 'publishes :message_status_changed Wisper event with previous + new status (AC3)' do
    collector = Class.new do
      attr_reader :received

      def initialize
        @received = []
      end

      def message_status_changed(data)
        @received << data
      end
    end.new

    service = described_class.new(message, 'delivered')
    service.subscribe(collector)
    service.perform

    expect(collector.received.size).to eq(1)
    received = collector.received.first[:data]
    expect(received).to include(
      message: message,
      previous_status: 'sent',
      status: 'delivered'
    )
  end

  it 'publishes external_error when status=failed' do
    allow(message).to receive(:status).and_return('sent')
    collector = []
    listener = Class.new do
      define_method(:message_status_changed) { |data| collector << data }
    end.new

    service = described_class.new(message, 'failed', 'invalid number')
    service.subscribe(listener)
    service.perform

    expect(collector.first[:data][:external_error]).to eq('invalid number')
  end

  it 'does not publish if the transition is invalid (read → delivered)' do
    allow(message).to receive_messages(status: 'read', read?: true)
    collector = []
    listener = Class.new do
      define_method(:message_status_changed) { |data| collector << data }
    end.new

    service = described_class.new(message, 'delivered')
    service.subscribe(listener)
    service.perform

    expect(collector).to be_empty
  end

  # AC1 (F-1) — same-status re-emission is dropped
  it 'AC1: rejects same-status re-emissions (delivered → delivered)' do
    allow(message).to receive_messages(status: 'delivered', delivered?: true)
    service = described_class.new(message, 'delivered')
    result, events = perform_and_capture(service)

    expect(result).to be(false)
    expect(events).to be_empty
    expect(message).not_to have_received(:update!)
  end

  # AC2 (F-2a) — read is terminal
  it 'AC2: rejects any transition out of read' do
    allow(message).to receive_messages(status: 'read', read?: true)

    %w[sent delivered failed].each do |target|
      service = described_class.new(message, target)
      result, events = perform_and_capture(service)
      expect(result).to be(false), "expected read → #{target} to be rejected"
      expect(events).to be_empty
    end
    expect(message).not_to have_received(:update!)
  end

  # AC3 (F-2b) — failed is terminal
  it 'AC3: rejects any transition out of failed' do
    allow(message).to receive_messages(status: 'failed', failed?: true)

    %w[sent delivered read].each do |target|
      service = described_class.new(message, target)
      result, events = perform_and_capture(service)
      expect(result).to be(false), "expected failed → #{target} to be rejected"
      expect(events).to be_empty
    end
    expect(message).not_to have_received(:update!)
  end

  # AC4 — delivered must not regress to sent
  it 'AC4: rejects delivered → sent regression' do
    allow(message).to receive_messages(status: 'delivered', delivered?: true)
    service = described_class.new(message, 'sent')
    result, events = perform_and_capture(service)

    expect(result).to be(false)
    expect(events).to be_empty
  end

  # AC5 — valid transitions from sent still work
  it 'AC5: preserves valid transitions from sent (sent → delivered/read/failed)' do
    %w[delivered read failed].each do |target|
      allow(message).to receive(:status).and_return('sent')
      service = described_class.new(message, target)
      result, events = perform_and_capture(service)

      expect(result).to be(true), "expected sent → #{target} to be accepted"
      expect(events.size).to eq(1)
      expect(events.first[:data]).to include(previous_status: 'sent', status: target)
    end
  end
end
