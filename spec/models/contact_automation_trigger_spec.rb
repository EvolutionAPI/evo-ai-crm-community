# frozen_string_literal: true

require 'rails_helper'

# Coverage for the narrow bridge that keeps contact-triggered automations alive
# even though Contact#dispatch_*_event (the broad dispatcher path) stays disabled.
RSpec.describe Contact, type: :model do
  before { allow(AutomationContactEventJob).to receive(:perform_later) }
  after { Current.reset }

  # The enqueue guard only fires when an active rule listens for the event, so
  # the "happy path" specs need one in place.
  def rule_for(event_name)
    rule = AutomationRule.new(name: 'r', event_name: event_name, active: true, mode: 'simple', conditions: [], actions: [])
    rule.save!(validate: false)
    rule
  end

  it 'enqueues a contact_created automation event on create' do
    rule_for('contact_created')

    contact = Contact.create!(name: 'New', email: "c-#{SecureRandom.hex(4)}@test.com")

    expect(AutomationContactEventJob).to have_received(:perform_later).with('contact_created', contact.id, anything)
  end

  it 'enqueues a contact_updated automation event on update' do
    rule_for('contact_updated')
    contact = Contact.create!(name: 'X', email: "c-#{SecureRandom.hex(4)}@test.com")

    contact.update!(name: 'Y')

    expect(AutomationContactEventJob).to have_received(:perform_later).with('contact_updated', contact.id, anything)
  end

  # Seam test (review follow-up): drive a REAL label change through the producer
  # path instead of injecting changed_attributes by hand, so after_update_commit →
  # enqueue is actually exercised for the acts-as-taggable-on setter.
  it 'enqueues a contact_updated automation event when labels change via update!(label_list:)' do
    rule_for('contact_updated')
    contact = Contact.create!(name: 'X', email: "c-#{SecureRandom.hex(4)}@test.com")

    contact.update!(label_list: ['vip'])

    expect(AutomationContactEventJob).to have_received(:perform_later).with('contact_updated', contact.id, anything)
  end

  it 'does NOT enqueue when no active rule listens for the event (rule guard)' do
    # Only an inactive rule exists → nothing should be enqueued.
    AutomationRule.new(name: 'off', event_name: 'contact_created', active: false, mode: 'simple', conditions: [],
                       actions: []).save!(validate: false)

    Contact.create!(name: 'New', email: "c-#{SecureRandom.hex(4)}@test.com")

    expect(AutomationContactEventJob).not_to have_received(:perform_later)
  end

  it 'does NOT enqueue when the change came from a running automation (loop guard)' do
    rule = rule_for('contact_updated')
    contact = Contact.create!(name: 'X', email: "c-#{SecureRandom.hex(4)}@test.com")
    Current.executed_by = rule

    contact.update!(name: 'Z')

    expect(AutomationContactEventJob).not_to have_received(:perform_later).with('contact_updated', contact.id, anything)
  end
end
