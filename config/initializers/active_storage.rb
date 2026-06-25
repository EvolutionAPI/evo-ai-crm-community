# frozen_string_literal: true

# Configure ActiveStorage for development environment
Rails.application.configure do
  # Skip SSL verification for S3-compatible services in development
  # This fixes SSL certificate verification issues with Cloudflare R2 in local development
  if Rails.env.development?
    require 'aws-sdk-s3'

    Aws.config.update(
      ssl_verify_peer: false,
      http_wire_trace: false  # Desabilitar trace HTTP para não poluir logs com dados binários
    )

    Rails.logger.info "🔓 ActiveStorage: SSL verification disabled for development environment"
  end
end

# Warn at boot when local storage is selected without an explicit public host.
# Without ACTIVE_STORAGE_URL, browser-facing URLs fall back to default_url_options
# (typically the container's internal hostname), which neither the user's browser
# nor sibling containers (Evolution API) can resolve — leading to the "grey blob"
# render bug and silent outbound delivery failures (EVO-1747).
if !Rails.env.test? &&
   ENV['ACTIVE_STORAGE_SERVICE'].to_s.downcase == 'local' &&
   ENV['ACTIVE_STORAGE_URL'].to_s.strip.empty?
  Rails.logger.warn '⚠️  ACTIVE_STORAGE_SERVICE=local but ACTIVE_STORAGE_URL is not set. ' \
                    'Inbound media will likely not render in the chat and outbound media ' \
                    'will not be delivered. Set ACTIVE_STORAGE_URL to a host reachable by ' \
                    'both the browser and sibling containers (see .env.example).'
end
