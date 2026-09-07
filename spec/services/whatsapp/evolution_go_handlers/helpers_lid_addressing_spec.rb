# frozen_string_literal: true

require 'rails_helper'

# WhatsApp addresses a contact that is not in the account's address book by LID
# ("192234817380569@lid") and sends no SenderAlt, so no phone number exists. The
# ingest must keep the "@lid" server: a 15-digit LID is indistinguishable from an
# E.164 number once the server is dropped, and Evolution Go's CreateJID turns any
# bare digit string into "<digits>@s.whatsapp.net", which WhatsApp refuses with
# "no LID found ... from server".
RSpec.describe Whatsapp::EvolutionGoHandlers::Helpers do
  subject(:handler) { harness.new(info) }

  let(:harness) do
    Class.new do
      include Whatsapp::EvolutionGoHandlers::Helpers

      def initialize(info)
        @evolution_go_info = info
      end

      # Helpers' methods are private; expose the ones under test.
      public :phone_number_from_jid, :lid_from_jid, :sender_jid, :contact_name,
             :is_whatsapp_phone_number?
    end
  end

  context 'when the chat is LID-addressed (contact not in the address book)' do
    let(:info) { { IsFromMe: false, IsGroup: false, Chat: '192234817380569@lid', PushName: 'Pruebas Dimarka' } }

    it 'does not expose the LID as a phone number' do
      expect(handler.phone_number_from_jid).to be_nil
    end

    it 'exposes the LID with its server preserved' do
      expect(handler.lid_from_jid).to eq('192234817380569@lid')
      expect(handler.sender_jid).to eq('192234817380569@lid')
    end

    it 'is not treated as a WhatsApp phone number' do
      expect(handler).not_to be_is_whatsapp_phone_number
    end
  end

  context 'when the chat is phone-addressed' do
    let(:info) { { IsFromMe: false, IsGroup: false, Chat: '557499879409:13@s.whatsapp.net', PushName: 'Ana' } }

    it 'extracts the number and drops the device suffix' do
      expect(handler.phone_number_from_jid).to eq('557499879409')
    end

    it 'reports no LID' do
      expect(handler.lid_from_jid).to be_nil
    end

    it 'is treated as a WhatsApp phone number' do
      expect(handler).to be_is_whatsapp_phone_number
    end
  end

  context 'when there is no PushName' do
    let(:info) { { IsFromMe: false, IsGroup: false, Chat: '192234817380569@lid' } }

    it 'falls back to the JID user part for the display name' do
      expect(handler.contact_name).to eq('192234817380569')
    end
  end
end
