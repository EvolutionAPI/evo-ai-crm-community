# frozen_string_literal: true

module EvoFlow
  # Raised at construction time for an unusable configuration (missing key,
  # invalid scheme, or cleartext transport in production). Fails fast instead
  # of emitting a request that is guaranteed to 401 or that leaks the shared
  # key over cleartext.
  #
  # Lives in its own file (not inside client.rb) so Zeitwerk can autoload it by
  # name: SegmentsController rescues it at class-body level, which resolves
  # during eager-load before client.rb would otherwise define it.
  class ConfigurationError < StandardError; end
end
