# frozen_string_literal: true

require 'rails_helper'

# A tela que abriu a aba do Hub so descobria a conexao num refresh manual. Os
# handlers passam a anunciar a transicao; estes exemplos prendem o contrato do
# anuncio nos dois sentidos e a garantia de que uma falha no anuncio nao desfaz
# a persistencia do canal.
RSpec.describe EvolutionHub::ConnectionBroadcast do
  let(:inbox) { instance_double(Inbox, id: 'inbox-1', blank?: false) }
  let(:channel) { instance_double(Channel::Whatsapp, id: 'chan-1', inbox: inbox) }
  let(:dispatcher) { instance_double(Dispatcher, dispatch: true) }

  let(:host) do
    Class.new do
      include EvolutionHub::ConnectionBroadcast
      def announce(channel, status) = broadcast_connection_change(channel, status)
    end.new
  end

  before { allow(Rails.configuration).to receive(:dispatcher).and_return(dispatcher) }

  it 'anuncia a conexao com a inbox, o canal e o estado' do
    host.announce(channel, described_class::CONNECTED)

    expect(dispatcher).to have_received(:dispatch).with(
      Events::Types::HUB_CHANNEL_CONNECTION_CHANGED,
      kind_of(ActiveSupport::TimeWithZone),
      hash_including(inbox: inbox, channel: channel, connection_status: 'connected')
    )
  end

  it 'anuncia a desconexao pelo mesmo caminho' do
    host.announce(channel, described_class::DISCONNECTED)

    expect(dispatcher).to have_received(:dispatch).with(
      Events::Types::HUB_CHANNEL_CONNECTION_CHANGED,
      kind_of(ActiveSupport::TimeWithZone),
      hash_including(connection_status: 'disconnected')
    )
  end

  it 'nao anuncia canal sem inbox' do
    orfao = instance_double(Channel::Whatsapp, id: 'chan-2', inbox: nil)

    host.announce(orfao, described_class::CONNECTED)

    expect(dispatcher).not_to have_received(:dispatch)
  end

  it 'engole a falha do anuncio para nao desfazer a persistencia do canal' do
    allow(dispatcher).to receive(:dispatch).and_raise(StandardError, 'cable fora do ar')

    expect { host.announce(channel, described_class::CONNECTED) }.not_to raise_error
  end
end
