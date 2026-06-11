# frozen_string_literal: true

require 'rails_helper'

# EVO-1551 round 4 — regression coverage for `build_contact_inbox`.
#
# When the PII masking flag strips `source_id` from `GET /contactable_inboxes`,
# the frontend echoes nothing back on `POST /conversations`. The controller
# already calls `.presence` on `params[:source_id]` so an empty string is
# treated as nil, but the builder must remain idempotent regardless of how
# the flag is configured — otherwise a flag-off install would regress.
RSpec.describe ContactInboxBuilder do
  let(:contact) { Contact.create!(name: 'Lead', phone_number: '+5511999998888', email: "leak-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://cibuilder.example.com') }
  let(:inbox) { Inbox.create!(name: 'CIB Inbox', channel: channel) }

  describe '#perform with nil source_id (flag-on round-trip)' do
    it 'auto-generates a UUID for Web Widget when none is provided' do
      contact_inbox = described_class.new(contact: contact, inbox: inbox, source_id: nil).perform
      expect(contact_inbox).to be_present
      expect(contact_inbox.source_id).to be_present
    end
  end

  describe '#perform with nil source_id on a phone-derived channel (flag-on round-trip)' do
    let(:whatsapp_channel) { Channel::Whatsapp.new(phone_number: '+5511111111111', provider: 'whatsapp_cloud', provider_config: { 'api_key' => 'x', 'phone_number_id' => '1', 'business_account_id' => '1' }) }
    let(:whatsapp_inbox) do
      whatsapp_channel.save(validate: false)
      Inbox.create!(name: 'WA Inbox', channel: whatsapp_channel)
    end

    it 'regenerates the WhatsApp source_id from contact.phone_number' do
      contact_inbox = described_class.new(contact: contact, inbox: whatsapp_inbox, source_id: nil).perform
      expect(contact_inbox.source_id).to eq('5511999998888')
    end

    it 'returns the existing ContactInbox when one already matches (idempotent)' do
      first = described_class.new(contact: contact, inbox: whatsapp_inbox, source_id: nil).perform
      second = described_class.new(contact: contact, inbox: whatsapp_inbox, source_id: nil).perform
      expect(second.id).to eq(first.id)
    end
  end

  describe '#perform with explicit source_id (flag-off path / non-PII channels)' do
    it 'honours the explicit source_id when provided (Web Widget / Api opaque ids)' do
      explicit = "ws-#{SecureRandom.hex(4)}"
      contact_inbox = described_class.new(contact: contact, inbox: inbox, source_id: explicit).perform
      expect(contact_inbox.source_id).to eq(explicit)
    end
  end
end
