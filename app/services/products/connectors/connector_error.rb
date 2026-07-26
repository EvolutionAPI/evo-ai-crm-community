# frozen_string_literal: true

module Products
  module Connectors
    # Raised for any connector failure the user can act on: a missing/invalid
    # credential, an unreachable store, or a non-2xx response from its API. The
    # controller maps it to a 422 with the message, so the import UI can surface it.
    class ConnectorError < StandardError; end
  end
end
