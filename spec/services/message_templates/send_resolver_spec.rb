# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageTemplates::SendResolver do
  let(:channel) { Channel::Api.create! }
  let(:other_channel) { Channel::Api.create! }

  def global_template(name:, content: 'Hi {{first_name}}')
    MessageTemplate.create!(name: name, content: content, channel: nil)
  end

  def channel_template(channel:, name:, content: 'Hi {{first_name}}')
    MessageTemplate.create!(name: name, content: content, channel: channel)
  end

  describe '#resolve by id' do
    it 'returns a global template by id' do
      template = global_template(name: 'global_welcome')
      resolved = described_class.new(id: template.id, channel: channel).resolve
      expect(resolved).to eq(template)
    end

    it 'returns a channel-bound template visible to the same channel' do
      template = channel_template(channel: channel, name: 'ch_welcome')
      resolved = described_class.new(id: template.id, channel: channel).resolve
      expect(resolved).to eq(template)
    end

    it 'returns nil for a template bound to a different channel' do
      template = channel_template(channel: other_channel, name: 'other_welcome')
      resolved = described_class.new(id: template.id, channel: channel).resolve
      expect(resolved).to be_nil
    end

    it 'returns nil for a non-existent id' do
      resolved = described_class.new(id: SecureRandom.uuid, channel: channel).resolve
      expect(resolved).to be_nil
    end

    it 'returns nil for an inactive template' do
      template = global_template(name: 'inactive_welcome')
      template.update!(active: false)
      resolved = described_class.new(id: template.id, channel: channel).resolve
      expect(resolved).to be_nil
    end
  end

  describe '#resolve by name' do
    it 'prefers the channel-bound template when both share a name' do
      global = global_template(name: 'welcome')
      channel_bound = channel_template(channel: channel, name: 'welcome')

      resolved = described_class.new(name: 'welcome', channel: channel).resolve

      expect(resolved).to eq(channel_bound)
      expect(resolved).not_to eq(global)
    end

    it 'falls back to the global template when the channel has none' do
      global = global_template(name: 'global_only')
      resolved = described_class.new(name: 'global_only', channel: channel).resolve
      expect(resolved).to eq(global)
    end

    it 'returns nil when neither channel nor global match the name' do
      resolved = described_class.new(name: 'missing', channel: channel).resolve
      expect(resolved).to be_nil
    end
  end

  it 'prefers id over name when both are given' do
    by_id = global_template(name: 'by_id')
    global_template(name: 'by_name')
    resolved = described_class.new(id: by_id.id, name: 'by_name', channel: channel).resolve
    expect(resolved).to eq(by_id)
  end
end
