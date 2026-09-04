# frozen_string_literal: true

require 'rails_helper'
require 'sidekiq/testing'

RSpec.describe EvoFlow::PurchaseEventsListener do
  let(:listener) { described_class.new }
  let(:pipeline) { instance_double(Pipeline, name: 'Compras') }
  let(:stage) { instance_double(PipelineStage, name: 'Compra recebida') }
  let(:contact) { instance_double(Contact, id: 42) }
  let(:pipeline_item) do
    instance_double(PipelineItem, id: 9, pipeline: pipeline, pipeline_id: 1, pipeline_stage: stage, pipeline_stage_id: 2)
  end
  let(:purchase) do
    { 'provider' => 'virtu', 'purchase_id' => 'ORD-1001', 'event' => 'approved',
      'product' => 'Curso X', 'amount' => 297.0, 'currency' => 'BRL' }
  end
  let(:event) do
    { contact: contact, pipeline_item: pipeline_item, provider: 'virtu', purchase: purchase,
      outcome: :created, new_contact: true }
  end

  before do
    Sidekiq::Testing.fake!
    EvoFlow::PublishEventWorker.clear
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return('test-key')
  end

  after { EvoFlow::PublishEventWorker.clear }

  def sent_payload
    EvoFlow::PublishEventWorker.jobs.last['args'][1]
  end

  it 'emits purchase.approved with the purchase as typed properties and the CRM contact' do
    listener.purchase_approved(data: event)

    job = EvoFlow::PublishEventWorker.jobs.last
    expect(job['args'][0]).to eq('/events/track')
    expect(sent_payload['event']).to eq('purchase.approved')
    expect(sent_payload['contactId']).to eq('42')
    expect(sent_payload['properties']).to include(
      'provider' => 'virtu', 'purchase_id' => 'ORD-1001', 'pipeline_id' => 1, 'pipeline_item_id' => 9,
      'source' => 'purchase_webhook', 'product' => 'Curso X', 'amount' => 297.0, 'currency' => 'BRL',
      'platform_event' => 'approved', 'outcome' => 'created', 'new_contact' => true,
      'pipeline_name' => 'Compras', 'pipeline_stage_name' => 'Compra recebida'
    )
  end

  # Buyer PII (name/e-mail/phone) stays in the CRM contact: the event carries
  # only what the schema declares, whatever else rides in the purchase hash.
  it 'forwards only schema-declared keys, never buyer PII' do
    leaked = purchase.merge('customer' => { 'email' => 'a@b.c' }, 'email' => 'a@b.c', 'phone' => '+5511999999999')
    listener.purchase_approved(data: event.merge(purchase: leaked))

    schema = EvoFlow::EventSchema.fetch('purchase.approved')
    declared = (schema[:required].keys + schema[:optional].keys).map(&:to_s)
    expect(sent_payload['properties'].keys - declared).to be_empty
    expect(sent_payload.to_json).not_to include('a@b.c', '+5511999999999')
  end

  # The evo-flow pipe rejects explicit null for typed fields.
  it 'omits optional fields the platform did not send instead of sending null' do
    listener.purchase_approved(data: event.merge(purchase: purchase.except('product', 'currency', 'amount')))

    expect(sent_payload['properties']).not_to have_key('product')
    expect(sent_payload['properties']).not_to have_key('amount')
    expect(sent_payload['properties']).to include('purchase_id' => 'ORD-1001')
  end

  it 'coerces a string amount into a number (the contract says number)' do
    listener.purchase_approved(data: event.merge(purchase: purchase.merge('amount' => '297.90')))

    expect(sent_payload['properties']['amount']).to eq(297.9)
  end

  it 'derives the same message_id for the same purchase, whatever the clock says' do
    listener.purchase_approved(data: event)
    first = sent_payload['messageId']
    EvoFlow::PublishEventWorker.clear
    travel_to(1.hour.from_now) { listener.purchase_approved(data: event) }

    expect(sent_payload['messageId']).to eq(first)
  end

  it 'reports a second sale on the open card as already_in_pipeline' do
    listener.purchase_approved(data: event.merge(outcome: :already_in_pipeline, new_contact: false))

    expect(sent_payload['properties']).to include('outcome' => 'already_in_pipeline', 'new_contact' => false)
  end

  it 'logs an error and does not enqueue without contact or pipeline_item' do
    expect(Rails.logger).to receive(:error).with(/contact or pipeline_item is nil/)
    listener.purchase_approved(data: event.merge(contact: nil))
    expect(EvoFlow::PublishEventWorker.jobs).to be_empty
  end

  it 'does not enqueue when EvoFlow is disabled' do
    allow(ENV).to receive(:[]).with('AUTH_APIKEY_INTEGRATION_LOCAL').and_return(nil)
    allow(ENV).to receive(:[]).with('EVO_FLOW_ENABLED').and_return(nil)

    listener.purchase_approved(data: event)
    expect(EvoFlow::PublishEventWorker.jobs).to be_empty
  end

  it 'returns early on an EventDispatcher payload' do
    listener.purchase_approved(Struct.new(:data).new(event))
    expect(EvoFlow::PublishEventWorker.jobs).to be_empty
  end

  it 'never raises: a builder failure is logged, not propagated to the webhook' do
    allow(EvoFlow::PayloadBuilder).to receive(:build_track).and_raise(EvoFlow::InvalidEventPayload, 'boom')
    expect(Rails.logger).to receive(:error).with(/PurchaseEventsListener#purchase_approved failed/)

    expect { listener.purchase_approved(data: event) }.not_to raise_error
  end
end
