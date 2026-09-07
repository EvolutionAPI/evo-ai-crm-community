# frozen_string_literal: true

require 'rails_helper'

# The source_id is what SendOnWhatsappService hands to Evolution Go as the
# destination, so it has to stay routable. See lid_addressing_spec.rb for why a
# LID must keep its "@lid" server.
RSpec.describe Whatsapp::EvolutionGoHandlers::MessagesUpsert do
  subject(:handler) { harness.new }

  let(:harness) do
    Class.new do
      include Whatsapp::EvolutionGoHandlers::MessagesUpsert

      public :determine_source_id
    end
  end

  it 'prefers SenderAlt, the resolved phone JID, when WhatsApp provides it' do
    expect(handler.determine_source_id('5511999999999@s.whatsapp.net', '5511999999999', nil))
      .to eq('5511999999999@s.whatsapp.net')
  end

  it 'keeps the "@lid" server when there is no SenderAlt' do
    expect(handler.determine_source_id(nil, nil, '192234817380569@lid')).to eq('192234817380569@lid')
  end

  it 'still uses the plain number for a phone-addressed chat' do
    expect(handler.determine_source_id(nil, '5511999999999', nil)).to eq('5511999999999')
  end
end
