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
      update!: true
    )
  end

  before do
    # avoid touching the global Wisper subscribers; we attach a temporary
    # collector to the service instance for the duration of the example.
    allow(Message).to receive(:statuses).and_return('sent' => 0, 'delivered' => 1, 'read' => 2, 'failed' => 3)
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
end
