module Sendgrid
  # SendGrid rejected the API key (401/403). Surfaced by the controller as a 422
  # so the channel is not persisted with an unusable key.
  class InvalidApiKeyError < ApiError; end
end
