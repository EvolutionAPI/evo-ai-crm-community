# frozen_string_literal: true

require_relative 'boot'
require_relative '../lib/evolution_app'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

## Load the specific APM agent
# We rely on DOTENV to load the environment variables
# We need these environment variables to load the specific APM agent
Dotenv::Rails.load
require 'ddtrace' if ENV.fetch('DD_TRACE_AGENT_URL', false).present?
require 'elastic-apm' if ENV.fetch('ELASTIC_APM_SECRET_TOKEN', false).present?
require 'scout_apm' if ENV.fetch('SCOUT_KEY', false).present?

if ENV.fetch('NEW_RELIC_LICENSE_KEY', false).present?
  require 'newrelic-sidekiq-metrics'
  require 'newrelic_rpm'
end

if ENV.fetch('SENTRY_DSN', false).present?
  require 'sentry-ruby'
  require 'sentry-rails'
  require 'sentry-sidekiq'
end

# heroku autoscaling
if ENV.fetch('JUDOSCALE_URL', false).present?
  require 'judoscale-rails'
  require 'judoscale-sidekiq'
end

module Evolution
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.0

    # Configure as API-only application
    config.api_only = true

    config.eager_load_paths << Rails.root.join('lib')

    # EvoFlow::EVENT_NAMES is grouped with Events::Types under lib/events/ but
    # its constant name does not match the Zeitwerk path. The ignore must be
    # configured before the autoloader is set up (an initializer would run too
    # late), so it lives here. The file is required explicitly so the constant
    # is always available and production eager_load does not raise NameError.
    evo_flow_event_names = Rails.root.join('lib/events/evo_flow_event_names.rb')
    Rails.autoloaders.main.ignore(evo_flow_event_names)
    require evo_flow_event_names.to_s

    evo_extension_points = Rails.root.join('lib/evo_extension_points.rb')
    Rails.autoloaders.main.ignore(evo_extension_points)
    require evo_extension_points.to_s

    # MCP resources/tools don't follow standard Rails naming patterns
    # Don't add to eager_load_paths - let them be loaded on-demand by Zeitwerk
    # config.eager_load_paths << Rails.root.join('app/mcp')
    config.eager_load_paths << Rails.root.join('app/middleware')

    # Settings in config/environments/* take precedence over those specified here.
    # Application configuration can go into files in config/initializers
    # -- all .rb files in that directory are automatically loaded after loading
    # the framework and any gems in your application.

    # API mode - no asset pipeline needed
    config.generators do |g|
      g.assets false
      g.helper false
      g.javascripts false
      g.stylesheets false
    end

    # Custom evolution configurations
    config.x = config_for(:app).with_indifferent_access

    # https://stackoverflow.com/questions/72970170/upgrading-to-rails-6-1-6-1-causes-psychdisallowedclass-tried-to-load-unspecif
    # https://discuss.rubyonrails.org/t/cve-2022-32224-possible-rce-escalation-bug-with-serialized-columns-in-active-record/81017
    # FIX ME : fixes breakage of installation config. we need to migrate.
    config.active_record.yaml_column_permitted_classes = [ActiveSupport::HashWithIndifferentAccess]


    ActiveRecord::Base.logger = ActiveSupport::Logger.new($stdout) if defined?(Rails::Console)
  end

  def self.config
    @config ||= Rails.configuration.x
  end

  def self.redis_ssl_verify_mode
    # Introduced this method to fix the issue in heroku where redis connections fail for redis 6
    # ref: https://github.com/evolution-api/evolution/issues/2420
    #
    # unless the redis verify mode is explicitly specified as none, we will fall back to the default 'verify peer'
    # ref: https://www.rubydoc.info/stdlib/openssl/OpenSSL/SSL/SSLContext#DEFAULT_PARAMS-constant
    ENV['REDIS_OPENSSL_VERIFY_MODE'] == 'none' ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
  end
end
