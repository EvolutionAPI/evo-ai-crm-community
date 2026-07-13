require_relative '../../lib/global_config_service'

Rails.application.configure do
  # Allow all hosts (traffic is already filtered by the API gateway/nginx)
  config.hosts.clear
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.cache_classes = true

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local       = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in either ENV["RAILS_MASTER_KEY"]
  # or in config/master.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Disable serving static files from the `/public` folder by default since
  # Apache or NGINX already handles this.
  config.public_file_server.enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch('RAILS_SERVE_STATIC_FILES', true))
  config.public_file_server.headers = {
    'Cache-Control' => "public, max-age=#{1.year.to_i}"
  }
  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = 'X-Sendfile' # for Apache
  # config.action_dispatch.x_sendfile_header = 'X-Accel-Redirect' # for NGINX

  # Storage service (see config/storage.yml). Resolve ONLY from the ENV — same as
  # staging.rb/development.rb — never from GlobalConfigService/DB.
  # EVO-2095: reading GlobalConfigService here gave the DB value precedence over
  # the ENV (default seed is `local`), and it queried the DB DURING boot config,
  # firing the active_storage_blob load hook before the service was assigned. The
  # result was non-deterministic across processes (puma -> S3, sidekiq -> Disk):
  # attachments landed on the container's ephemeral disk and were lost on redeploy.
  # Storage is boot infrastructure — it must be ENV-driven and deterministic.
  config.active_storage.service = ENV.fetch('ACTIVE_STORAGE_SERVICE', 'local').to_sym

  # Attachments are served by the app (ActiveStorage proxy) so the internal
  # S3/MinIO endpoint never reaches the browser — presigned URLs embed the host
  # in the SigV4 signature and cannot be rewritten (EVO-2006).
  # ATTACHMENT_DELIVERY=redirect rolls back to storage redirects (requires a
  # storage host reachable by browsers and sibling containers).
  # Security note: proxy blob URLs carry a permanent signed id (anyone with the
  # link can fetch the file, same as a leaked presigned URL but without expiry);
  # outbound URLs handed to providers keep a 15-minute TTL (BlobUrlOptions).
  config.active_storage.resolve_model_to_route =
    ENV.fetch('ATTACHMENT_DELIVERY', 'proxy').casecmp('redirect').zero? ? :rails_storage_redirect : :rails_storage_proxy

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = ActiveModel::Type::Boolean.new.cast(ENV.fetch('FORCE_SSL', false))

  # Use the lowest log level to ensure availability of diagnostic information
  # when problems arise.
  config.log_level = ENV.fetch('LOG_LEVEL', 'info').to_sym

  # Prepend all log lines with the following tags.
  config.log_tags = [:request_id]

  # Use a different cache store in production.
  config.cache_store = :redis_cache_store, { url: ENV['REDIS_URL'] }

  # Use a real queuing backend for Active Job (and separate queues per environment)
  config.active_job.queue_adapter = :sidekiq
  # config.active_job.queue_name_prefix = "Evolution_#{Rails.env}"

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = [I18n.default_locale]

  # Send deprecation notices to registered listeners.
  config.active_support.deprecation = :notify

  # Use default logging formatter so that PID and timestamp are not suppressed.
  config.log_formatter = ::Logger::Formatter.new

  # Use a different logger for distributed setups.
  # require 'syslog/logger'
  # config.logger = ActiveSupport::TaggedLogging.new(Syslog::Logger.new 'app-name')

  if ActiveModel::Type::Boolean.new.cast(ENV.fetch('RAILS_LOG_TO_STDOUT', true))
    logger           = ActiveSupport::Logger.new($stdout)
    logger.formatter = config.log_formatter
    config.logger    = ActiveSupport::TaggedLogging.new(logger)
  else
    config.logger    = ActiveSupport::Logger.new(
      Rails.root.join("log/#{Rails.env}.log"),
      1,
      ENV.fetch('LOG_SIZE', '1024').to_i.megabytes
    )
  end

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  config.action_mailer.perform_caching = false

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Inbound email ingress (:relay | :mailgun | :mandrill | :postmark | :sendgrid) is
  # configured once, ENV-first, in config/initializers/mailer.rb — the single source
  # of truth. Initializers load AFTER this environment file, so any assignment here
  # would be overwritten by mailer.rb anyway. EVO-2096: it must never be resolved from
  # GlobalConfigService/DB at boot (DB value would take precedence over the ENV and
  # fire a DB query during boot config, non-deterministic across processes).

  # BACKEND_URL must be a publicly reachable URL in production. A missing, malformed, or
  # localhost value silently breaks webhook callbacks and Active Storage URLs sent to
  # external integrations.
  backend_url_value = ENV['BACKEND_URL'].to_s.strip
  parsed_backend_url = (URI.parse(backend_url_value) rescue nil)
  parsed_host = parsed_backend_url&.host.to_s.downcase

  if backend_url_value.empty? || parsed_host.empty? || %w[localhost 127.0.0.1].include?(parsed_host)
    raise "BACKEND_URL must be set to a public URL in production (got: #{backend_url_value.inspect})"
  end

  Rails.application.routes.default_url_options = {
    host: parsed_backend_url.host,
    port: parsed_backend_url.port,
    protocol: parsed_backend_url.scheme
  }
end
