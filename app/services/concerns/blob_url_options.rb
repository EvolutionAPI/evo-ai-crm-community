# Resolves effective ActiveStorage URL options, honoring ENV['ACTIVE_STORAGE_URL']
# when present so generated URLs (Attachment#file_url/#thumb_url, DiskService
# signed URLs, etc.) target a host reachable from the consumer.
#
# Used by:
# - Browser-facing model URL builders (Attachment#file_url/#thumb_url)
# - Macro / AutomationRule file previews (Macro#file_base_data, AutomationRule#file_base_data)
# - Sidekiq paths that hand DiskService URLs to external services (Evolution API / Evolution Go)
module BlobUrlOptions
  module_function

  def effective_url_options(base = Rails.application.routes.default_url_options)
    base = (base || {}).dup
    return base if ENV['ACTIVE_STORAGE_URL'].blank?

    storage_uri = URI.parse(ENV['ACTIVE_STORAGE_URL'])
    base.merge(
      host: storage_uri.host,
      port: storage_uri.port,
      protocol: storage_uri.scheme
    )
  rescue URI::InvalidURIError => e
    Rails.logger.warn "[BlobUrlOptions] Invalid ACTIVE_STORAGE_URL=#{ENV['ACTIVE_STORAGE_URL'].inspect}: #{e.message}. Falling back to default_url_options."
    base
  end

  # Scopes ActiveStorage::Current.url_options to effective_url_options for the
  # duration of the block, restoring whatever was set before. Use this around
  # any url_for(blob_or_attached) / blob.url call so the generated host honors
  # ENV['ACTIVE_STORAGE_URL'] without leaking the override to unrelated callers.
  def with_scoped_url_options
    previous = ActiveStorage::Current.url_options
    ActiveStorage::Current.url_options = effective_url_options
    yield
  ensure
    ActiveStorage::Current.url_options = previous
  end
end
