# frozen_string_literal: true

# Transicao de conexao de um canal Meta intermediado pelo Evo Hub, empurrada
# para a tela do operador que ficou esperando o retorno da aba do Hub.
#
# Vive num concern proprio e nao no corpo do ActionCableListener porque aquela
# classe ja estava no teto do Metrics/ClassLength: somar um metodo la obrigaria
# a afrouxar o cop para todo mundo.
module HubChannelConnectionEvents
  include Events::Types

  # Vai para todos os usuarios, e nao so para quem clicou: o cadastro pode ser
  # retomado de outra aba ou por outro operador, e o estado e do canal.
  def hub_channel_connection_changed(event)
    inbox = event.data[:inbox]
    return if inbox.blank?

    payload = {
      inbox_id: inbox.id,
      channel_type: inbox.channel_type,
      connection_status: event.data[:connection_status]
    }

    # Instalacao single-tenant: Inbox nao expoe `account`.
    broadcast(single_tenant_account, User.pluck(:pubsub_token).compact.uniq,
              HUB_CHANNEL_CONNECTION_CHANGED, payload)
  end
end
