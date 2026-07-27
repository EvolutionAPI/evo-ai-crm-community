# frozen_string_literal: true

module Products
  module Connectors
    # A connector failure the user can act on (bad credential, unreachable store, non-2xx).
    # The controller maps it to a 422 carrying the message.
    class ConnectorError < StandardError; end
  end
end
