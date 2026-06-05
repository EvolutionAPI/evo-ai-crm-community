# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutomationContactEventJob do
  let(:contact) { Contact.create!(name: 'Jane', email: "c-#{SecureRandom.hex(4)}@test.com") }

  it 'invokes the automation listener for a supported contact event' do
    listener = instance_double(AutomationRuleListener, contact_updated: nil)
    allow(AutomationRuleListener).to receive(:instance).and_return(listener)

    described_class.perform_now('contact_updated', contact.id, { 'name' => %w[a b] })

    expect(listener).to have_received(:contact_updated) do |event|
      expect(event.data[:contact]).to eq(contact)
      expect(event.data[:changed_attributes]).to eq({ 'name' => %w[a b] })
    end
  end

  it 'ignores unsupported event names' do
    allow(AutomationRuleListener).to receive(:instance)
    described_class.perform_now('contact_deleted', contact.id, {})
    expect(AutomationRuleListener).not_to have_received(:instance)
  end

  it 'no-ops when the contact no longer exists' do
    listener = instance_double(AutomationRuleListener, contact_updated: nil)
    allow(AutomationRuleListener).to receive(:instance).and_return(listener)

    described_class.perform_now('contact_updated', SecureRandom.uuid, {})

    expect(listener).not_to have_received(:contact_updated)
  end
end
