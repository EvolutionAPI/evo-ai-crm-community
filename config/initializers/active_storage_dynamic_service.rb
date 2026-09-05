# frozen_string_literal: true

# Overrides ActiveStorage::Blob.service so the provider is resolved at request time
# and not only at boot. The ENV wins: the installation_configs value applies only
# where the ENV is unset, and there web and Sidekiq converge within one Redis cache
# cycle of the admin switching providers.
#
# Caveat: S3 credentials are still read at boot from config/storage.yml ERB —
# changing them in the UI requires a service restart.
Rails.application.config.after_initialize do
  next if ActiveStorage::Blob.respond_to?(:_static_service)

  ActiveStorage::Blob.class_eval do
    # Each bucket-backed service reads its bucket/container name from a
    # DIFFERENT ENV/GlobalConfig key (see config/storage.yml). Map them
    # explicitly so the fail-safe below checks the right key per provider —
    # e.g. google uses GCS_BUCKET and microsoft uses AZURE_STORAGE_CONTAINER,
    # NOT STORAGE_BUCKET_NAME.
    BUCKET_ENV_BY_SERVICE = {
      's3_compatible' => 'STORAGE_BUCKET_NAME',
      'amazon'        => 'S3_BUCKET_NAME',
      'google'        => 'GCS_BUCKET',
      'microsoft'     => 'AZURE_STORAGE_CONTAINER'
    }.freeze
    BUCKET_BACKED_SERVICES = BUCKET_ENV_BY_SERVICE.keys.freeze

    class << self
      alias_method :_static_service, :service

      def service
        service_name = resolved_service_name

        # Fail-safe: if a bucket-backed service is selected but no bucket is
        # configured, aws-sdk raises at every request and self-hosted stacks
        # become unusable. Fall back to :local so the CRM stays functional
        # instead of crashing (EVO-1961).
        if BUCKET_BACKED_SERVICES.include?(service_name) && !bucket_configured?(service_name)
          warn_bucket_fallback(service_name)
          service_name = 'local'
        end

        key = service_name.to_sym
        resolved = respond_to?(:services) ? services.fetch(key) { nil } : nil
        unless resolved
          Rails.logger.warn("[ActiveStorage] service '#{service_name}' not registered (built at boot); falling back to boot-time default")
        end
        resolved || _static_service
      rescue StandardError => e
        Rails.logger.warn("[ActiveStorage] failed to resolve dynamic service: #{e.message}; falling back to boot-time default")
        _static_service
      end

      private

      # ENV wins over the DB: production.rb resolves the service from the ENV and
      # installation_config.yml documents the DB value as informational. The DB is
      # only consulted when the ENV is unset.
      def resolved_service_name
        GlobalConfigService.load_env_first('ACTIVE_STORAGE_SERVICE', 'local').presence || 'local'
      end

      def bucket_configured?(service_name)
        bucket_env = BUCKET_ENV_BY_SERVICE[service_name]
        # Unknown/unmapped service: don't second-guess it — let it resolve.
        return true if bucket_env.nil?

        bucket_name(service_name, bucket_env).to_s.strip.present?
      end

      # Only s3_compatible reads its bucket from the DB in config/storage.yml; for the
      # ENV-only providers a DB row promises a bucket the service never receives. An
      # unreadable value counts as unconfigured so the fail-safe falls back to :local.
      def bucket_name(service_name, bucket_env)
        return ENV.fetch(bucket_env, nil) unless service_name == 's3_compatible'

        GlobalConfigService.load_env_first(bucket_env, nil)
      rescue StandardError
        nil
      end

      # `service` is a hot path — it runs for every attachment URL and blob
      # operation — so warning on each call would flood the logs on a
      # media-heavy page. Only warn when the offending service changes.
      def warn_bucket_fallback(service_name)
        return if @warned_bucket_fallback == service_name

        @warned_bucket_fallback = service_name
        Rails.logger.warn("[ActiveStorage] '#{service_name}' selected but bucket not configured; falling back to :local")
      end
    end
  end
end
