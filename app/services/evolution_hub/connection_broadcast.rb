# frozen_string_literal: true

# Anuncia para a tela a mudanca de estado de conexao de um canal Meta
# intermediado pelo Hub. Compartilhado pelos handlers de `channel_connected` e
# `channel_disconnected`, que sao simetricos: manter uma copia em cada um
# convidava a divergencia entre os dois sentidos.
#
# Sem este empurrao, a tela que abriu a aba do Hub so descobre a conexao num
# refresh manual — a dor que originou o card.
#
# Falha aqui NAO desfaz a persistencia: o canal ja mudou de estado de fato, e
# nao avisar a tela e menos grave do que estourar e reprocessar o webhook.
module EvolutionHub
  module ConnectionBroadcast
    CONNECTED = 'connected'
    DISCONNECTED = 'disconnected'

    private

    def broadcast_connection_change(channel, status)
      inbox = channel.inbox
      return if inbox.blank?

      Rails.configuration.dispatcher.dispatch(
        Events::Types::HUB_CHANNEL_CONNECTION_CHANGED,
        Time.zone.now,
        inbox: inbox,
        channel: channel,
        connection_status: status
      )
    rescue StandardError => e
      Rails.logger.error(
        "EvolutionHub: falha ao anunciar #{status} do canal #{channel.id}: #{e.class}: #{e.message}"
      )
    end
  end
end
