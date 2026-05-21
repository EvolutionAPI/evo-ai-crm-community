# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe EvoFlow::ContactEventsListener do
  let(:listener) { described_class.new }
  let(:created_at) { Time.utc(2026, 5, 20, 10, 0, 0) }
  let(:updated_at) { Time.utc(2026, 5, 20, 11, 0, 0) }
  let(:contact) do
    instance_double(
      Contact,
      id: 42,
      name: 'Ada Lovelace',
      email: 'ada@example.com',
      phone_number: '+5511999999999',
      identifier: 'ext-1',
      middle_name: nil,
      last_name: 'Lovelace',
      location: 'SP',
      country_code: 'BR',
      contact_type: 'lead',
      blocked: false,
      created_at: created_at,
      updated_at: updated_at,
      custom_attributes: { 'tier' => 'gold' },
      additional_attributes: { 'created_via_user_id' => nil }
    )
  end
  let(:fixed_digest) { 'fixed-digest' }

  before do
    Sidekiq::Testing.fake!
    EvoFlow::PublishEventWorker.clear
    allow(EvoFlow::PayloadBuilder).to receive(:message_id_for).and_return(fixed_digest)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return('test-key')
  end

  after { EvoFlow::PublishEventWorker.clear }

  def last_payload
    EvoFlow::PublishEventWorker.jobs.last['args'][1]
  end

  describe '#contact_created' do
    let(:payload) { { contact: contact } }

    it 'enqueues an identify event with contact traits + created_via=system (AC1)' do
      listener.contact_created(data: payload)

      jobs = EvoFlow::PublishEventWorker.jobs
      expect(jobs.size).to eq(1)
      expect(jobs.last['args'][0]).to eq('/events/identify')
      sent = jobs.last['args'][1]
      expect(sent['eventName']).to eq('contact.created')
      expect(sent['contactId']).to eq('42')
      expect(sent['messageId']).to eq(fixed_digest)
      expect(sent['traits']).to include(
        'id' => 42,
        'email' => 'ada@example.com',
        'phone_number' => '+5511999999999',
        'source' => 'contact_created',
        'created_via' => 'system'
      )
      # M4: custom and additional attributes are namespaced rather than spread.
      expect(sent['traits']).to include('customAttributes' => { 'tier' => 'gold' })
      expect(sent['traits']).to include('additionalAttributes' => {})
    end

    # M4: a custom attribute named `id` (or any structural trait key) must not
    # overwrite the structural trait value.
    it 'does not let a custom_attribute named "id" overwrite the structural id' do
      allow(contact).to receive(:custom_attributes).and_return('id' => 'CUSTOM', 'name' => 'CUSTOM')

      listener.contact_created(data: payload)

      sent = last_payload
      expect(sent['traits']['id']).to eq(42)
      expect(sent['traits']['name']).to eq('Ada Lovelace')
      expect(sent['traits']['customAttributes']).to include('id' => 'CUSTOM', 'name' => 'CUSTOM')
    end

    it 'marks created_via=agent when additional_attributes.created_via_user_id is present' do
      allow(contact).to receive(:additional_attributes).and_return('created_via_user_id' => 7)

      listener.contact_created(data: payload)

      expect(last_payload['traits']).to include('created_via' => 'agent')
    end

    context 'when ENV is absent (AC12)' do
      before { allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil) }

      it 'does not enqueue and emits no error log' do
        expect(Rails.logger).not_to receive(:error)
        listener.contact_created(data: payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload (AC13)' do
      it 'returns early and does not enqueue' do
        event = Struct.new(:data).new(payload)
        listener.contact_created(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when contact is missing (AC14)' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/contact_created.*contact is nil/)
        listener.contact_created(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end
  end

  describe '#contact_updated' do
    let(:payload) { { contact: contact, changed_attributes: { 'email' => ['old@x.com', 'new@x.com'] } } }

    it 'enqueues an identify event with changes summary (AC2)' do
      listener.contact_updated(data: payload)

      sent = last_payload
      expect(sent['eventName']).to eq('contact.updated')
      expect(sent['traits']['source']).to eq('contact_updated')
      expect(sent['traits']['changes']).to eq('email' => 'new@x.com')
    end

    it 'also accepts `changes:` shape (spec idiom)' do
      listener.contact_updated(data: { contact: contact, changes: { 'name' => %w[old new] } })

      expect(last_payload['traits']['changes']).to eq('name' => 'new')
    end

    context 'when ENV is absent (AC12)' do
      before { allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil) }

      it 'does not enqueue and emits no error log' do
        expect(Rails.logger).not_to receive(:error)
        listener.contact_updated(data: payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload (AC13)' do
      it 'returns early and does not enqueue' do
        event = Struct.new(:data).new(payload)
        listener.contact_updated(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when contact is missing (AC14)' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/contact_updated.*contact is nil/)
        listener.contact_updated(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end
  end

  describe '#contact_deleted' do
    let(:deleted_at) { Time.utc(2026, 5, 20, 12, 0, 0) }
    let(:payload) { { contact_id: 99, reason: 'gdpr_erasure', deleted_at: deleted_at } }

    it 'enqueues an identify event with reason + deleted_at (AC3)' do
      listener.contact_deleted(data: payload)

      sent = last_payload
      expect(sent['eventName']).to eq('contact.deleted')
      expect(sent['contactId']).to eq('99')
      expect(sent['traits']).to include(
        'source' => 'contact_deleted',
        'reason' => 'gdpr_erasure',
        'deleted_at' => deleted_at.iso8601
      )
    end

    it 'defaults reason to user_action when missing' do
      listener.contact_deleted(data: { contact_id: 99, deleted_at: deleted_at })

      expect(last_payload['traits']['reason']).to eq('user_action')
    end

    it 'accepts `contact:` shape from the live publisher' do
      listener.contact_deleted(data: { contact: contact, deleted_at: deleted_at })

      expect(last_payload['contactId']).to eq('42')
    end

    context 'when ENV is absent (AC12)' do
      before { allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil) }

      it 'does not enqueue and emits no error log' do
        expect(Rails.logger).not_to receive(:error)
        listener.contact_deleted(data: payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload (AC13)' do
      it 'returns early and does not enqueue' do
        event = Struct.new(:data).new(payload)
        listener.contact_deleted(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when neither contact nor contact_id is present (AC14)' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/contact_deleted.*contact_id is nil/)
        listener.contact_deleted(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end
  end

  describe '#contact_label_added' do
    let(:payload) { { contact: contact, label_name: 'vip' } }

    it 'enqueues contact.label.added with labelName trait (AC4)' do
      listener.contact_label_added(data: payload)

      sent = last_payload
      expect(sent['eventName']).to eq('contact.label.added')
      expect(sent['traits']).to include('labelName' => 'vip', 'labelId' => 'vip', 'source' => 'label_added')
    end

    context 'when ENV is absent (AC12)' do
      before { allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil) }

      it 'does not enqueue and emits no error log' do
        expect(Rails.logger).not_to receive(:error)
        listener.contact_label_added(data: payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload (AC13)' do
      it 'returns early and does not enqueue' do
        event = Struct.new(:data).new(payload)
        listener.contact_label_added(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when contact is missing (AC14)' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/contact_label_added.*contact is nil/)
        listener.contact_label_added(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end
  end

  describe '#contact_label_removed' do
    let(:payload) { { contact: contact, label_name: 'vip' } }

    it 'enqueues contact.label.removed with labelName trait (AC4)' do
      listener.contact_label_removed(data: payload)

      sent = last_payload
      expect(sent['eventName']).to eq('contact.label.removed')
      expect(sent['traits']).to include('labelName' => 'vip', 'labelId' => 'vip', 'source' => 'label_removed')
    end

    context 'when ENV is absent (AC12)' do
      before { allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil) }

      it 'does not enqueue and emits no error log' do
        expect(Rails.logger).not_to receive(:error)
        listener.contact_label_removed(data: payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload (AC13)' do
      it 'returns early and does not enqueue' do
        event = Struct.new(:data).new(payload)
        listener.contact_label_removed(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when contact is missing (AC14)' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/contact_label_removed.*contact is nil/)
        listener.contact_label_removed(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end
  end

  describe '#contact_custom_attribute_changed' do
    let(:payload) do
      {
        contact: contact,
        attribute_name: 'tier',
        attribute_value: 'gold',
        change_type: 'updated',
        old_value: 'silver'
      }
    end

    it 'enqueues contact.custom_attribute.changed with all four trait keys (AC5)' do
      listener.contact_custom_attribute_changed(data: payload)

      sent = last_payload
      expect(sent['eventName']).to eq('contact.custom_attribute.changed')
      expect(sent['traits']).to include(
        'attributeName' => 'tier',
        'attributeValue' => 'gold',
        'changeType' => 'updated',
        'oldValue' => 'silver',
        'source' => 'custom_attribute_changed'
      )
    end

    context 'when ENV is absent (AC12)' do
      before { allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil) }

      it 'does not enqueue and emits no error log' do
        expect(Rails.logger).not_to receive(:error)
        listener.contact_custom_attribute_changed(data: payload)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when called with an EventDispatcher payload (AC13)' do
      it 'returns early and does not enqueue' do
        event = Struct.new(:data).new(payload)
        listener.contact_custom_attribute_changed(event)
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end

    context 'when contact is missing (AC14)' do
      it 'logs an error and does not enqueue' do
        expect(Rails.logger).to receive(:error).with(/contact_custom_attribute_changed.*contact is nil/)
        listener.contact_custom_attribute_changed(data: {})
        expect(EvoFlow::PublishEventWorker.jobs).to be_empty
      end
    end
  end

  describe 'rescue safety (AC15)' do
    it 'logs the error and returns nil when build_identify raises' do
      allow(EvoFlow::PayloadBuilder).to receive(:build_identify).and_raise(ArgumentError, 'boom')

      expect(Rails.logger).to receive(:error).with(/contact_created failed: ArgumentError: boom/)
      expect(listener.contact_created(data: { contact: contact })).to be_nil
      expect(EvoFlow::PublishEventWorker.jobs).to be_empty
    end
  end

  describe 'message_id idempotency (AC17)' do
    before { allow(EvoFlow::PayloadBuilder).to receive(:message_id_for).and_call_original }

    it 'produces identical messageId for two firings of the same record event' do
      2.times { listener.contact_created(data: { contact: contact }) }

      jobs = EvoFlow::PublishEventWorker.jobs
      expect(jobs.size).to eq(2)
      expect(jobs[0]['args'][1]['messageId']).to eq(jobs[1]['args'][1]['messageId'])
    end

    # F1: live publisher omits :deleted_at — we fall back to contact.updated_at
    # so retries collapse to one messageId.
    it 'contact_deleted on the live `contact:` shape is idempotent across firings' do
      2.times { listener.contact_deleted(data: { contact: contact }) }

      jobs = EvoFlow::PublishEventWorker.jobs
      expect(jobs.size).to eq(2)
      expect(jobs[0]['args'][1]['messageId']).to eq(jobs[1]['args'][1]['messageId'])
    end
  end

  # F5: documents the lossy JSON round-trip. BigDecimal becomes a String,
  # Time loses sub-second precision but survives as ISO8601. If consumers
  # require lossless transport this spec fails first.
  describe 'JSON normalisation fidelity (F5)' do
    let(:big_decimal) { BigDecimal('1.5') }
    let(:custom_attr_time) { Time.utc(2026, 5, 20, 9, 30, 15) }

    before do
      allow(contact).to receive(:custom_attributes).and_return(
        'amount' => big_decimal,
        'last_seen' => custom_attr_time
      )
    end

    it 'serialises BigDecimal as String (documented loss)' do
      listener.contact_created(data: { contact: contact })

      traits = EvoFlow::PublishEventWorker.jobs.last['args'][1]['traits']
      expect(traits['amount']).to eq('1.5')
    end

    it 'serialises Time as ISO8601 String' do
      listener.contact_created(data: { contact: contact })

      traits = EvoFlow::PublishEventWorker.jobs.last['args'][1]['traits']
      expect(traits['last_seen']).to start_with('2026-05-20T09:30:15')
      expect(traits['last_seen']).to end_with('Z')
    end
  end

  describe 'enqueue-loss observability (F6/F8)' do
    let(:payload) { { contact: contact } }

    it 'tags Redis outage at error level with [enqueue-loss] prefix' do
      stub_const('Redis::BaseConnectionError', Class.new(StandardError)) unless defined?(Redis::BaseConnectionError)
      allow(EvoFlow::PublishEventWorker).to receive(:perform_async)
        .and_raise(Redis::BaseConnectionError, 'redis down')

      expect(Rails.logger).to receive(:error).with(/\[EvoFlow\]\[enqueue-loss\].*Redis::BaseConnectionError/)
      expect { listener.contact_created(data: payload) }.not_to raise_error
    end

    it 'tags nil-occurred_at ArgumentError with [enqueue-loss] prefix' do
      allow(EvoFlow::PayloadBuilder).to receive(:build_identify)
        .and_raise(ArgumentError, 'occurred_at is required (no implicit Time.current fallback)')

      expect(Rails.logger).to receive(:error).with(/\[EvoFlow\]\[enqueue-loss\].*ArgumentError/)
      listener.contact_created(data: payload)
    end
  end
end
