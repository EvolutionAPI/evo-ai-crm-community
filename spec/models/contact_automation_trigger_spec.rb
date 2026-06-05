# frozen_string_literal: true

require 'rails_helper'

# Coverage for the narrow bridge that keeps contact-triggered automations alive
# even though Contact#dispatch_*_event (the broad dispatcher path) stays disabled.
RSpec.describe Contact, type: :model do
  before { allow(AutomationContactEventJob).to receive(:perform_later) }
  after { Current.reset }

  it 'enqueues a contact_created automation event on create' do
    contact = Contact.create!(name: 'New', email: "c-#{SecureRandom.hex(4)}@test.com")

    expect(AutomationContactEventJob).to have_received(:perform_later).with('contact_created', contact.id, anything)
  end

  it 'enqueues a contact_updated automation event on update' do
    contact = Contact.create!(name: 'X', email: "c-#{SecureRandom.hex(4)}@test.com")

    contact.update!(name: 'Y')

    expect(AutomationContactEventJob).to have_received(:perform_later).with('contact_updated', contact.id, anything)
  end

  it 'does NOT enqueue when the change came from a running automation (loop guard)' do
    contact = Contact.create!(name: 'X', email: "c-#{SecureRandom.hex(4)}@test.com")
    rule = AutomationRule.new(name: 'r', event_name: 'contact_updated', active: true, mode: 'simple', conditions: [], actions: [])
    rule.save!(validate: false)
    Current.executed_by = rule

    contact.update!(name: 'Z')

    expect(AutomationContactEventJob).not_to have_received(:perform_later).with('contact_updated', contact.id, anything)
  end
end
