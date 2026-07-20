# frozen_string_literal: true

require 'rails_helper'

# EVO-2179: BotRuntime::DelegationService must forward incoming media attachments to
# the bot_runtime. The @message it receives is an unpersisted Message.new (only id),
# so build_attachments reloads the persisted record via the conversation and maps its
# ActiveStorage media attachments to {url, content_type, file_type}.
RSpec.describe BotRuntime::DelegationService do
  subject(:service) { described_class.new(agent_bot, message, conversation) }

  let(:agent_bot) { double('agent_bot') }
  let(:message) { double('message', id: 42) }
  let(:messages_relation) { double('messages_relation') }
  let(:conversation) { double('conversation', messages: messages_relation) }

  def attachment(file_type:, attached: true, with_attached: true, content_type: 'image/png',
                 url: 'https://crm.example.com/rails/active_storage/blobs/proxy/photo.png')
    file = double('file', attached?: attached, content_type: content_type)
    double('attachment', file: file, with_attached_file?: with_attached, download_url: url, file_type: file_type)
  end

  def stub_persisted_with(attachments)
    persisted = double('persisted_message', attachments: attachments)
    allow(messages_relation).to receive(:find_by).with(id: 42).and_return(persisted)
  end

  describe '#build_attachments' do
    it 'reloads the persisted message and maps media attachments' do
      stub_persisted_with([attachment(file_type: 'image')])

      expect(service.send(:build_attachments)).to eq(
        [{
          url: 'https://crm.example.com/rails/active_storage/blobs/proxy/photo.png',
          content_type: 'image/png',
          file_type: 'image'
        }]
      )
    end

    it 'maps multiple media attachments (image + audio)' do
      atts = [
        attachment(file_type: 'image', content_type: 'image/jpeg', url: 'https://c/img.jpg'),
        attachment(file_type: 'audio', content_type: 'audio/ogg', url: 'https://c/a.ogg')
      ]
      stub_persisted_with(atts)

      result = service.send(:build_attachments)
      expect(result.map { |a| a[:file_type] }).to eq(%w[image audio])
      expect(result.map { |a| a[:content_type] }).to eq(['image/jpeg', 'audio/ogg'])
    end

    it 'returns [] when the persisted message is not found' do
      allow(messages_relation).to receive(:find_by).with(id: 42).and_return(nil)
      expect(service.send(:build_attachments)).to eq([])
    end

    it 'skips attachments whose file is not attached' do
      stub_persisted_with([attachment(file_type: 'image', attached: false)])
      expect(service.send(:build_attachments)).to eq([])
    end

    it 'skips non-media attachments (e.g. location)' do
      stub_persisted_with([attachment(file_type: 'location', with_attached: false)])
      expect(service.send(:build_attachments)).to eq([])
    end

    it 'never raises: logs and returns [] on error' do
      allow(messages_relation).to receive(:find_by).and_raise(StandardError.new('boom'))
      allow(Rails.logger).to receive(:error)

      expect(service.send(:build_attachments)).to eq([])
      expect(Rails.logger).to have_received(:error).with(/build_attachments failed/)
    end
  end
end
