# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionHandlers::MessagesUpsert' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

# Same dedup guard as the Cloud API service, same leak: released on the last
# line of the happy path, so a raise anywhere before it pins the Redis key for
# its full one-day TTL and every retry of that message is discarded silently.
RSpec.describe Whatsapp::EvolutionHandlers::MessagesUpsert do
  # The real service is the host: the upsert module leans on set_conversation,
  # which lives up in the base service, not in the module itself.
  let(:host_class) { Class.new(Whatsapp::IncomingMessageEvolutionService) }
  let(:inbox) { instance_double(Inbox) }
  let(:host) { host_class.new(inbox: inbox, params: {}) }

  before do
    allow(host).to receive(:message_type).and_return('text')
    allow(host).to receive(:message_processable?).and_return(true)
    allow(host).to receive(:raw_message_id).and_return('evo.race')
    allow(host).to receive(:cache_message_source_id_in_redis)
  end

  describe '#handle_message dedup guard release' do
    it 'releases the guard when set_contact raises, and still lets the exception reach Sidekiq' do
      allow(host).to receive(:set_contact).and_raise(ActiveRecord::RecordNotUnique.new('duplicate key'))

      expect(host).to receive(:clear_message_source_id_from_redis)
      expect { host.send(:handle_message) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'releases the guard when the payload carries no usable contact' do
      allow(host).to receive(:set_contact)

      expect(host).to receive(:clear_message_source_id_from_redis)
      host.send(:handle_message)
    end

    it 'still releases the guard on the happy path' do
      allow(host).to receive(:set_contact) { host.instance_variable_set(:@contact, instance_double(Contact)) }
      allow(host).to receive(:set_conversation)
      allow(host).to receive(:update_conversation_status_if_needed)
      allow(host).to receive(:handle_create_message)

      expect(host).to receive(:clear_message_source_id_from_redis)
      host.send(:handle_message)
    end
  end
end
