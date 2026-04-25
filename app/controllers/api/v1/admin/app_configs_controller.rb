module Api
  module V1
    module Admin
      class AppConfigsController < BaseController
        CONFIG_TYPES = {
          'smtp' => %w[
            SMTP_ADDRESS SMTP_PORT SMTP_USERNAME SMTP_PASSWORD_SECRET
            SMTP_AUTHENTICATION SMTP_DOMAIN SMTP_ENABLE_STARTTLS_AUTO
            SMTP_OPENSSL_VERIFY_MODE MAILER_SENDER_EMAIL MAILER_TYPE
            RESEND_API_SECRET BMS_API_SECRET BMS_IPPOOL
          ],
          'storage' => %w[ACTIVE_STORAGE_SERVICE STORAGE_BUCKET_NAME STORAGE_ACCESS_KEY_ID
                          STORAGE_ACCESS_SECRET STORAGE_REGION STORAGE_ENDPOINT],
          'google_oauth' => %w[GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_OAUTH_CALLBACK_URL],
          'facebook' => %w[FB_APP_ID FB_VERIFY_TOKEN FB_APP_SECRET FACEBOOK_API_VERSION
                           ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT FB_FEED_COMMENTS_ENABLED],
          'whatsapp' => %w[WP_APP_ID WP_VERIFY_TOKEN WP_APP_SECRET WP_WHATSAPP_CONFIG_ID WP_API_VERSION],
          'instagram' => %w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET INSTAGRAM_VERIFY_TOKEN
                            INSTAGRAM_API_VERSION ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT],
          'evolution' => %w[EVOLUTION_API_URL EVOLUTION_ADMIN_SECRET],
          'evolution_go' => %w[EVOLUTION_GO_API_URL EVOLUTION_GO_ADMIN_SECRET],
          'openai' => %w[
            OPENAI_API_URL OPENAI_API_SECRET OPENAI_MODEL OPENAI_ENABLE_AUDIO_TRANSCRIPTION
            OPENAI_PROMPT_REPLY OPENAI_PROMPT_SUMMARY OPENAI_PROMPT_REPHRASE
            OPENAI_PROMPT_FIX_GRAMMAR OPENAI_PROMPT_SHORTEN OPENAI_PROMPT_EXPAND
            OPENAI_PROMPT_FRIENDLY OPENAI_PROMPT_FORMAL OPENAI_PROMPT_SIMPLIFY
          ],
          'linear' => %w[LINEAR_CLIENT_ID LINEAR_CLIENT_SECRET],
          'hubspot' => %w[HUBSPOT_CLIENT_ID HUBSPOT_CLIENT_SECRET],
          'shopify' => %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET],
          'slack' => %w[SLACK_CLIENT_ID SLACK_CLIENT_SECRET],
          'microsoft' => %w[AZURE_APP_ID AZURE_APP_SECRET],
          'twitter' => %w[TWITTER_APP_ID TWITTER_CONSUMER_KEY TWITTER_CONSUMER_SECRET TWITTER_ENVIRONMENT],
          'inbound_email' => %w[
            RAILS_INBOUND_EMAIL_SERVICE RAILS_INBOUND_EMAIL_PASSWORD_SECRET
            MAILER_INBOUND_EMAIL_DOMAIN MAILGUN_SIGNING_SECRET MANDRILL_API_SECRET
          ],
          'push_notifications' => %w[FIREBASE_PROJECT_ID FIREBASE_CREDENTIALS_SECRET
                                     IOS_APP_ID ANDROID_BUNDLE_ID],
          'frontend_runtime' => %w[RECAPTCHA_SITE_KEY CLARITY_PROJECT_ID]
        }.freeze

        # Required-key enforcement: see `IntegrationRequirements` for the per-integration
        # map. Kept centralized so `GlobalConfigController#show` reports the same truth
        # via `hasXxxConfig` booleans.

        def show
          config_type = params[:config_type]
          allowed_keys = CONFIG_TYPES[config_type]
          return config_type_not_found unless allowed_keys

          configs = build_config_response(allowed_keys)
          success_response(data: { config_type: config_type, configs: configs })
        end

        def create
          config_type = params[:config_type]
          allowed_keys = CONFIG_TYPES[config_type]
          return config_type_not_found unless allowed_keys

          missing = missing_required_keys(config_type, allowed_keys)
          return missing_required_response(missing) if missing.any?

          save_configs(allowed_keys)
          configs = build_config_response(allowed_keys)
          success_response(data: { config_type: config_type, configs: configs }, message: 'Configuration updated successfully')
        end

        def test_connection
          config_type = params[:config_type]
          allowed_keys = CONFIG_TYPES[config_type]
          return config_type_not_found unless allowed_keys

          result = run_connection_test(config_type)
          success_response(data: result, message: result[:message])
        end

        private

        def build_config_response(allowed_keys)
          configs_by_name = InstallationConfig.where(name: allowed_keys).index_by(&:name)
          result = {}
          allowed_keys.each do |key|
            config = configs_by_name[key]
            result[key] = if config
                            config.sensitive? ? config.masked_value : config.value
                          end
          end
          result
        end

        def save_configs(allowed_keys)
          config_params = params.require(:app_config).permit(*allowed_keys)
          ActiveRecord::Base.transaction do
            allowed_keys.each do |key|
              next unless config_params.key?(key)

              value = config_params[key]
              next if value.nil? && key.end_with?('_SECRET')

              GlobalConfig.set(key, value)
            end
          end
        end

        def run_connection_test(config_type)
          case config_type
          when 'smtp'
            mailer_type = GlobalConfigService.load('MAILER_TYPE', 'smtp')
            case mailer_type
            when 'bms' then ConfigTest::BmsTestService.new.call
            when 'resend' then ConfigTest::ResendTestService.new.call
            else ConfigTest::SmtpTestService.new.call
            end
          when 'storage'
            ConfigTest::StorageTestService.new.call
          else
            { success: false, message: "Connection testing not supported for #{config_type}" }
          end
        end

        def config_type_not_found
          error_response(
            ApiErrorCodes::INVALID_PARAMETER,
            "Unknown config type: #{params[:config_type]}",
            status: :not_found
          )
        end

        # Returns the list of required keys whose effective value (incoming param or
        # existing DB value) would remain blank after the save.
        #
        # Payload convention: `save_configs` treats `nil` on a `_SECRET` key as
        # "preserve the existing DB value" — the frontend sends `nil` when the
        # admin didn't modify a secret field. So for required-check purposes we
        # must fall back to the stored value (DB or ENV) in that case, otherwise
        # every re-save with an untouched secret reports it as missing.
        def missing_required_keys(config_type, allowed_keys)
          required = IntegrationRequirements.required_keys(config_type)
          return [] if required.empty?

          incoming = params.fetch(:app_config, {}).permit(*allowed_keys).to_h

          required.select do |key|
            effective =
              if !incoming.key?(key) || (incoming[key].nil? && key.end_with?('_SECRET'))
                GlobalConfigService.load(key, nil)
              else
                incoming[key]
              end
            effective.to_s.strip.empty?
          end
        end

        def missing_required_response(missing)
          error_response(
            ApiErrorCodes::MISSING_REQUIRED_FIELD,
            "Missing required configuration: #{missing.join(', ')}",
            details: { missing: missing },
            status: :bad_request
          )
        end
      end
    end
  end
end
