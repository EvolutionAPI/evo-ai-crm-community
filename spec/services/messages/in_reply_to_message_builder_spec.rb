# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Messages::InReplyToMessageBuilder' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Messages::InReplyToMessageBuilder do
  let(:content_attributes) { {} }
  let(:message) { instance_double(Message, conversation: conversation, content_attributes: content_attributes) }
  let(:conversation) { instance_double(Conversation, messages: messages_relation) }
  let(:messages_relation) { instance_double(ActiveRecord::Relation) }

  describe '#perform' do
    context 'when in_reply_to (internal id) resolves to a parent message' do
      let(:parent) { instance_double(Message, id: 42, source_id: 'wamid.ABC') }

      it 'sets both in_reply_to and in_reply_to_external_id from the resolved parent' do
        allow(messages_relation).to receive(:find_by).with(id: 42).and_return(parent)

        described_class.new(message: message, in_reply_to: 42, in_reply_to_external_id: nil).perform

        expect(content_attributes[:in_reply_to]).to eq(42)
        expect(content_attributes[:in_reply_to_external_id]).to eq('wamid.ABC')
      end
    end

    context 'when only in_reply_to_external_id is present and resolves by source_id' do
      let(:parent) { instance_double(Message, id: 99, source_id: 'wamid.XYZ') }

      it 'sets both in_reply_to and in_reply_to_external_id' do
        allow(messages_relation).to receive(:find_by).with(source_id: 'wamid.XYZ').and_return(parent)

        described_class.new(message: message, in_reply_to: nil, in_reply_to_external_id: 'wamid.XYZ').perform

        expect(content_attributes[:in_reply_to]).to eq(99)
        expect(content_attributes[:in_reply_to_external_id]).to eq('wamid.XYZ')
      end
    end

    context 'when parent message cannot be resolved' do
      it 'preserves the original in_reply_to_external_id instead of wiping it' do
        content_attributes[:in_reply_to_external_id] = 'wamid.UNKNOWN'
        allow(messages_relation).to receive(:find_by).with(source_id: 'wamid.UNKNOWN').and_return(nil)

        described_class.new(message: message, in_reply_to: nil, in_reply_to_external_id: 'wamid.UNKNOWN').perform

        expect(content_attributes[:in_reply_to_external_id]).to eq('wamid.UNKNOWN')
        expect(content_attributes).not_to have_key(:in_reply_to)
      end

      it 'preserves the original in_reply_to when looked up by id but not found' do
        content_attributes[:in_reply_to] = 12_345
        allow(messages_relation).to receive(:find_by).with(id: 12_345).and_return(nil)

        described_class.new(message: message, in_reply_to: 12_345, in_reply_to_external_id: nil).perform

        expect(content_attributes[:in_reply_to]).to eq(12_345)
        expect(content_attributes).not_to have_key(:in_reply_to_external_id)
      end
    end

    context 'when both in_reply_to and in_reply_to_external_id are blank' do
      it 'is a no-op' do
        described_class.new(message: message, in_reply_to: nil, in_reply_to_external_id: nil).perform

        expect(content_attributes).to be_empty
      end
    end
  end
end
