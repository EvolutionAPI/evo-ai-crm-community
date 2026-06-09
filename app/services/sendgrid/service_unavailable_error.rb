module Sendgrid
  # SendGrid was unreachable or returned 5xx — distinct from an invalid key so
  # the smoke test answers 503 instead of 422, and webhook registration can mark
  # the channel `failed` for later retry.
  class ServiceUnavailableError < ApiError; end
end
