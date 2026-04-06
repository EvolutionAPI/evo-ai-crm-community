Rails.application.configure do
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

  # Store uploaded files on the local file system (see config/storage.yml for options)
  config.active_storage.service = GlobalConfigService.load('ACTIVE_STORAGE_SERVICE', ENV.fetch('ACTIVE_STORAGE_SERVICE', 'local')).to_sym

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

  # Set this to appropriate ingress service for which the options are :
  # :relay for Exim, Postfix, Qmail
  # :mailgun for Mailgun
  # :mandrill for Mandrill
  # :postmark for Postmark
  # :sendgrid for Sendgrid
  config.action_mailbox.ingress = (GlobalConfigService.load('RAILS_INBOUND_EMAIL_SERVICE', ENV.fetch('RAILS_INBOUND_EMAIL_SERVICE', 'relay')) rescue ENV.fetch('RAILS_INBOUND_EMAIL_SERVICE', 'relay')).to_sym

  # Use BACKEND_URL for Active Storage and route URLs
  backend_url = URI.parse(ENV.fetch('BACKEND_URL', 'http://localhost:3000'))
  Rails.application.routes.default_url_options = {
    host: backend_url.host,
    port: backend_url.port,
    protocol: backend_url.scheme
  }
end
