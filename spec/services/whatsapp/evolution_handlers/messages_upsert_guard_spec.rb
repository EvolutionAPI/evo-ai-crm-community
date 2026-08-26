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

# Same dedup guard as the Cloud API service, and it used to leak the same way:
# released on the last line of the happy path, so a raise before it pinned the
# Redis key for its full one-day TTL and every retry was discarded silently.
RSpec.describe Whatsapp::EvolutionHandlers::MessagesUpsert do
  let(:guard_key) { format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: 'evo.race') }
  let(:fake_alfred) { {} }
  let(:inbox) { instance_double(Inbox) }
  let(:params) { { event: 'messages.upsert', data: { key: { id: 'evo.race' } } } }
  # The module leans on set_conversation, which lives up in the base service, so the
  # real Evolution service is the host that exercises it.
  let(:host) { Whatsapp::IncomingMessageEvolutionService.new(inbox: inbox, params: params) }

  before do
    # In-memory Alfred (repo convention) so the real cache/clear helpers run and
    # the assertions are about the key itself, not about the call site.
    allow(Redis::Alfred).to receive(:setex) { |key, value, _expiry = nil| fake_alfred[key] = value }
    allow(Redis::Alfred).to receive(:get) { |key| fake_alfred[key] }
    allow(Redis::Alfred).to receive(:delete) { |key| fake_alfred.delete(key) }

    # evolution_api? reads @processed_params directly, and #perform is what memoizes
    # it - handle_message is driven here without going through #perform.
    host.send(:processed_params)
    allow(host).to receive(:message_type).and_return('text')
    allow(host).to receive(:message_processable?).and_return(true)
    allow(host).to receive(:raw_message_id).and_return('evo.race')
  end

  describe '#handle_message dedup guard release' do
    it 'releases the guard when set_contact raises, and still lets the exception reach Sidekiq' do
      allow(host).to receive(:set_contact) do
        expect(fake_alfred).to include(guard_key)
        raise ActiveRecord::RecordNotUnique, 'duplicate key'
      end

      expect { host.send(:handle_message) }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(fake_alfred).to be_empty
    end

    it 'releases the guard when the payload carries no usable contact' do
      allow(host).to receive(:set_contact)

      host.send(:handle_message)
      expect(fake_alfred).to be_empty
    end

    it 'still releases the guard on the happy path' do
      allow(host).to receive(:set_contact) do
        expect(fake_alfred).to include(guard_key)
        host.instance_variable_set(:@contact, instance_double(Contact))
      end
      allow(host).to receive(:set_conversation)
      allow(host).to receive(:update_conversation_status_if_needed)
      allow(host).to receive(:handle_create_message)

      host.send(:handle_message)
      expect(fake_alfred).to be_empty
    end

    # The `ensure` must not reach the early returns above it: they exist because
    # another worker holds the guard, and clearing it there would undo the dedup.
    it 'leaves the guard alone when another worker is already processing the message' do
      allow(host).to receive(:message_processable?).and_return(false)
      fake_alfred[guard_key] = 'true'

      expect(host).not_to receive(:set_contact)
      host.send(:handle_message)
      expect(fake_alfred).to include(guard_key)
    end

    it 'does not let a Redis failure in the ensure mask the exception that killed the message' do
      allow(host).to receive(:set_contact).and_raise(ActiveRecord::RecordNotUnique.new('duplicate key'))
      allow(Redis::Alfred).to receive(:delete).and_raise(Redis::CannotConnectError)

      expect { host.send(:handle_message) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
