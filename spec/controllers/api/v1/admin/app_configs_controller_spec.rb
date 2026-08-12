require 'rails_helper'

RSpec.describe Api::V1::Admin::AppConfigsController, type: :controller do
  let(:admin_user) do
    user = User.create!(email: 'admin@example.com', name: 'Admin User')
    allow(user).to receive(:administrator?).and_return(true)
    user
  end

  let(:regular_user) do
    user = User.create!(email: 'agent@example.com', name: 'Agent User')
    allow(user).to receive(:administrator?).and_return(false)
    allow(user).to receive(:has_permission?).and_return(false)
    user
  end

  before do
    ENV['ENCRYPTION_KEY'] = 'test-encryption-key-for-fernet!!'
    InstallationConfig.reset_encryption_key_cache!
    # The model invalidates the GlobalConfig cache from after_commit, which never
    # fires under transactional fixtures. Without this, values cached by one example
    # answer the reads of the next one.
    GlobalConfig.clear_cache
  end

  after do
    Current.reset
    InstallationConfig.reset_encryption_key_cache!
  end

  shared_context 'authenticated admin' do
    before do
      Current.user = admin_user
      allow(controller).to receive(:authenticate_request!).and_return(true)
    end
  end

  shared_context 'authenticated non-admin' do
    before do
      Current.user = regular_user
      allow(controller).to receive(:authenticate_request!).and_return(true)
    end
  end

  describe 'GET #show' do
    context 'when not authenticated' do
      it 'returns 401' do
        get :show, params: { config_type: 'smtp' }, format: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated as non-admin' do
      include_context 'authenticated non-admin'

      it 'returns unauthorized' do
        get :show, params: { config_type: 'smtp' }, format: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated as admin' do
      include_context 'authenticated admin'

      context 'with valid config type' do
        before do
          InstallationConfig.create!(name: 'SMTP_ADDRESS', serialized_value: { 'value' => 'smtp.example.com' })
          InstallationConfig.create!(name: 'SMTP_PORT', serialized_value: { 'value' => 587 })
          InstallationConfig.create!(name: 'SMTP_PASSWORD_SECRET', serialized_value: { 'value' => 'my-secret-password' })
        end

        it 'returns configs for the requested type with masked secrets' do
          get :show, params: { config_type: 'smtp' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['success']).to be true

          configs = body['data']['configs']
          expect(configs['SMTP_ADDRESS']).to eq('smtp.example.com')
          expect(configs['SMTP_PORT']).to eq(587)
          expect(configs['SMTP_PASSWORD_SECRET']).to start_with(described_class::MASK_PREFIX)
        end

        it 'returns all keys for the config type including nil for missing ones' do
          get :show, params: { config_type: 'smtp' }, format: :json

          body = JSON.parse(response.body)
          configs = body['data']['configs']
          expected_keys = Api::V1::Admin::AppConfigsController::CONFIG_TYPES['smtp']
          expect(configs.keys).to match_array(expected_keys)
          expect(configs['MAILER_SENDER_EMAIL']).to be_nil
          expect(configs['BMS_IPPOOL']).to be_nil
        end

        it 'returns the correct config_type in response' do
          get :show, params: { config_type: 'smtp' }, format: :json

          body = JSON.parse(response.body)
          expect(body['data']['config_type']).to eq('smtp')
        end
      end

      context 'with storage config type' do
        before do
          InstallationConfig.create!(name: 'ACTIVE_STORAGE_SERVICE', serialized_value: { 'value' => 's3_compatible' })
          InstallationConfig.create!(name: 'STORAGE_BUCKET_NAME', serialized_value: { 'value' => 'my-bucket' })
          InstallationConfig.create!(name: 'STORAGE_ACCESS_KEY_ID', serialized_value: { 'value' => 'AKIA12345' })
          InstallationConfig.create!(name: 'STORAGE_ACCESS_SECRET', serialized_value: { 'value' => 'super-secret-key' })
          InstallationConfig.create!(name: 'STORAGE_REGION', serialized_value: { 'value' => 'us-east-1' })
          InstallationConfig.create!(name: 'STORAGE_ENDPOINT', serialized_value: { 'value' => 'https://s3.example.com' })
        end

        it 'returns all 6 storage keys' do
          get :show, params: { config_type: 'storage' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          configs = body['data']['configs']
          expected_keys = %w[ACTIVE_STORAGE_SERVICE STORAGE_BUCKET_NAME STORAGE_ACCESS_KEY_ID
                             STORAGE_ACCESS_SECRET STORAGE_REGION STORAGE_ENDPOINT]
          expect(configs.keys).to match_array(expected_keys)
        end

        it 'masks STORAGE_ACCESS_SECRET' do
          get :show, params: { config_type: 'storage' }, format: :json

          body = JSON.parse(response.body)
          configs = body['data']['configs']
          expect(configs['STORAGE_ACCESS_SECRET']).to start_with(described_class::MASK_PREFIX)
          expect(configs['STORAGE_ACCESS_SECRET']).not_to eq('super-secret-key')
        end

        it 'returns plain values for non-secret keys' do
          get :show, params: { config_type: 'storage' }, format: :json

          body = JSON.parse(response.body)
          configs = body['data']['configs']
          expect(configs['ACTIVE_STORAGE_SERVICE']).to eq('s3_compatible')
          expect(configs['STORAGE_BUCKET_NAME']).to eq('my-bucket')
          expect(configs['STORAGE_ACCESS_KEY_ID']).to eq('AKIA12345')
          expect(configs['STORAGE_REGION']).to eq('us-east-1')
          expect(configs['STORAGE_ENDPOINT']).to eq('https://s3.example.com')
        end
      end


      context 'with evolution_hub config type' do
        before do
          InstallationConfig.create!(name: 'EVOLUTION_HUB_ENABLED', serialized_value: { 'value' => 'true' })
          InstallationConfig.create!(name: 'EVOLUTION_HUB_API_KEY', serialized_value: { 'value' => 'hub-bearer-token-1234' })
        end

        it 'masks EVOLUTION_HUB_API_KEY (non-_SECRET bearer credential)' do
          get :show, params: { config_type: 'evolution_hub' }, format: :json

          body = JSON.parse(response.body)
          configs = body['data']['configs']
          expect(configs['EVOLUTION_HUB_API_KEY']).to start_with(described_class::MASK_PREFIX)
          expect(configs['EVOLUTION_HUB_API_KEY']).not_to eq('hub-bearer-token-1234')
          expect(configs['EVOLUTION_HUB_API_KEY']).to end_with('1234')
        end

        it 'returns plain value for non-secret keys' do
          get :show, params: { config_type: 'evolution_hub' }, format: :json

          body = JSON.parse(response.body)
          configs = body['data']['configs']
          # #show returns the raw stored value; boolean typecast only happens on the
          # GlobalConfigService.load path, so the stored String comes back verbatim.
          expect(configs['EVOLUTION_HUB_ENABLED']).to eq('true')
        end
      end

      context 'with unknown config type' do
        it 'returns 404 with error' do
          get :show, params: { config_type: 'unknown_type' }, format: :json

          expect(response).to have_http_status(:not_found)
          body = JSON.parse(response.body)
          expect(body['success']).to be false
          expect(body['error']['code']).to eq('INVALID_PARAMETER')
          expect(body['error']['message']).to include('unknown_type')
        end
      end
    end
  end

  describe 'POST #create' do
    context 'when not authenticated' do
      it 'returns 401' do
        post :create, params: { config_type: 'smtp', app_config: { SMTP_ADDRESS: 'new.smtp.com' } }, format: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated as non-admin' do
      include_context 'authenticated non-admin'

      it 'returns unauthorized' do
        post :create, params: { config_type: 'smtp', app_config: { SMTP_ADDRESS: 'new.smtp.com' } }, format: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated as admin' do
      include_context 'authenticated admin'

      before do
        redis_double = double('redis')
        allow($alfred).to receive(:with).and_yield(redis_double)
        allow(redis_double).to receive(:get).and_return(nil)
        allow(redis_double).to receive(:set).and_return(true)
        allow(redis_double).to receive(:del).and_return(true)
        allow(redis_double).to receive(:keys).and_return([])
        allow(redis_double).to receive(:expire).and_return(true)
      end

      context 'with valid config type' do
        it 'saves allowed keys and returns updated configs' do
          post :create, params: {
            config_type: 'smtp',
            app_config: { SMTP_ADDRESS: 'new.smtp.com', SMTP_PORT: '465' }
          }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['success']).to be true
          expect(body['message']).to eq('Configuration updated successfully')

          configs = body['data']['configs']
          expect(configs['SMTP_ADDRESS']).to eq('new.smtp.com')
          expect(configs['SMTP_PORT']).to eq('465')
        end

        it 'ignores keys not in the allowed list' do
          post :create, params: {
            config_type: 'smtp',
            app_config: { SMTP_ADDRESS: 'new.smtp.com', HACKER_KEY: 'bad-value' }
          }, format: :json

          expect(response).to have_http_status(:ok)
          expect(InstallationConfig.find_by(name: 'HACKER_KEY')).to be_nil
        end

        it 'preserves existing value when sensitive key is null' do
          InstallationConfig.create!(name: 'SMTP_PASSWORD_SECRET', serialized_value: { 'value' => 'existing-secret' })

          post :create, params: {
            config_type: 'smtp',
            app_config: { SMTP_PASSWORD_SECRET: nil, SMTP_ADDRESS: 'new.smtp.com' }
          }, format: :json

          expect(response).to have_http_status(:ok)
          config = InstallationConfig.find_by(name: 'SMTP_PASSWORD_SECRET')
          expect(config.value).not_to be_nil
        end

        it 'encrypts EVOLUTION_HUB_API_KEY at rest' do
          # evolution_hub requires BOTH keys (IntegrationRequirements); send both so
          # missing_required_keys passes and the save actually runs.
          post :create, params: {
            config_type: 'evolution_hub',
            app_config: {
              EVOLUTION_HUB_API_KEY: 'hub-bearer-token-1234',
              EVOLUTION_HUB_WEBHOOK_SECRET: 'hub-webhook-secret'
            }
          }, format: :json

          expect(response).to have_http_status(:ok)
          config = InstallationConfig.find_by(name: 'EVOLUTION_HUB_API_KEY')
          # Stored ciphertext is a Fernet token, but decrypts to the real value.
          expect(config.serialized_value['value']).to start_with('gAAAAA')
          expect(config.value).to eq('hub-bearer-token-1234')
        end

        it 'never overwrites EVOLUTION_HUB_API_KEY with a masked sentinel' do
          InstallationConfig.create!(name: 'EVOLUTION_HUB_API_KEY', serialized_value: { 'value' => 'real-hub-token' })
          # Seed the paired required secret so missing_required_keys falls back to it
          # (the payload only touches the API key).
          InstallationConfig.create!(name: 'EVOLUTION_HUB_WEBHOOK_SECRET', serialized_value: { 'value' => 'wh-secret' })

          post :create, params: {
            config_type: 'evolution_hub',
            app_config: { EVOLUTION_HUB_API_KEY: '••••••••1234' }
          }, format: :json

          expect(response).to have_http_status(:ok)
          config = InstallationConfig.find_by(name: 'EVOLUTION_HUB_API_KEY')
          expect(config.value).to eq('real-hub-token')
        end

        it 'preserves existing EVOLUTION_HUB_API_KEY when sent as null' do
          InstallationConfig.create!(name: 'EVOLUTION_HUB_API_KEY', serialized_value: { 'value' => 'real-hub-token' })
          InstallationConfig.create!(name: 'EVOLUTION_HUB_WEBHOOK_SECRET', serialized_value: { 'value' => 'wh-secret' })

          post :create, params: {
            config_type: 'evolution_hub',
            app_config: { EVOLUTION_HUB_API_KEY: nil, EVOLUTION_HUB_ENABLED: 'true' }
          }, format: :json

          expect(response).to have_http_status(:ok)
          config = InstallationConfig.find_by(name: 'EVOLUTION_HUB_API_KEY')
          expect(config.value).to eq('real-hub-token')
        end

        it 'clears Redis cache after saving' do
          redis_double = double('redis')
          allow($alfred).to receive(:with).and_yield(redis_double)
          allow(redis_double).to receive(:get).and_return(nil)
          allow(redis_double).to receive(:set).and_return(true)
          allow(redis_double).to receive(:keys).and_return([])
          allow(redis_double).to receive(:expire).and_return(true)

          expect(redis_double).to receive(:del).at_least(:once)

          post :create, params: {
            config_type: 'evolution',
            app_config: {
              EVOLUTION_API_URL: 'https://api.example.com',
              EVOLUTION_ADMIN_SECRET: 'secret-xyz'
            }
          }, format: :json

          expect(response).to have_http_status(:ok)
        end
      end

      context 'with unknown config type' do
        it 'returns 404 with error' do
          post :create, params: { config_type: 'nonexistent', app_config: { KEY: 'value' } }, format: :json

          expect(response).to have_http_status(:not_found)
          body = JSON.parse(response.body)
          expect(body['success']).to be false
          expect(body['error']['code']).to eq('INVALID_PARAMETER')
        end
      end

      context 'with missing app_config parameter' do
        it 'returns error response' do
          post :create, params: { config_type: 'smtp' }, format: :json

          expect(response).to have_http_status(:unprocessable_entity).or have_http_status(:bad_request)
          body = JSON.parse(response.body)
          expect(body['success']).to be false
        end
      end

      context 'with required keys enforcement' do
        # Exercises `IntegrationRequirements::CONFIG_TYPE_REQUIRED_KEYS` end-to-end:
        # blank payload + empty DB rejects, omitted + populated DB accepts (partial
        # update), and full payload persists.
        integrations = {
          'facebook' => {
            required: %w[FB_APP_ID FB_APP_SECRET FB_VERIFY_TOKEN],
            full: { FB_APP_ID: 'fb-1', FB_APP_SECRET: 'fb-secret', FB_VERIFY_TOKEN: 'fb-token' }
          },
          'whatsapp' => {
            required: %w[WP_APP_ID WP_APP_SECRET WP_VERIFY_TOKEN WP_WHATSAPP_CONFIG_ID],
            full: { WP_APP_ID: 'wp-1', WP_APP_SECRET: 'wp-secret', WP_VERIFY_TOKEN: 'wp-token',
                    WP_WHATSAPP_CONFIG_ID: 'cfg-1' }
          },
          'instagram' => {
            required: %w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET INSTAGRAM_VERIFY_TOKEN],
            full: { INSTAGRAM_APP_ID: 'ig-1', INSTAGRAM_APP_SECRET: 'ig-secret',
                    INSTAGRAM_VERIFY_TOKEN: 'ig-token' }
          },
          'evolution' => {
            required: %w[EVOLUTION_API_URL EVOLUTION_ADMIN_SECRET],
            full: { EVOLUTION_API_URL: 'https://api.example.com', EVOLUTION_ADMIN_SECRET: 'ev-secret' }
          },
          'evolution_go' => {
            required: %w[EVOLUTION_GO_API_URL EVOLUTION_GO_ADMIN_SECRET],
            full: { EVOLUTION_GO_API_URL: 'https://go.example.com', EVOLUTION_GO_ADMIN_SECRET: 'go-secret' }
          },
          'twitter' => {
            required: %w[TWITTER_APP_ID TWITTER_CONSUMER_KEY TWITTER_CONSUMER_SECRET TWITTER_ENVIRONMENT],
            full: { TWITTER_APP_ID: 'tw-1', TWITTER_CONSUMER_KEY: 'tw-key',
                    TWITTER_CONSUMER_SECRET: 'tw-secret', TWITTER_ENVIRONMENT: 'dev' }
          }
        }

        integrations.each do |config_type, data|
          context "for #{config_type}" do
            let(:required_keys) { data[:required] }
            let(:full_payload) { data[:full] }
            let(:first_required) { required_keys.first }
            let(:rest_required) { required_keys[1..] }

            before do
              InstallationConfig.where(name: required_keys).delete_all
            end

            it 'rejects save when a required key is blank in payload and unset in db' do
              payload = full_payload.dup
              payload[first_required.to_sym] = ''

              post :create, params: { config_type: config_type, app_config: payload }, format: :json

              expect(response).to have_http_status(:bad_request)
              body = JSON.parse(response.body)
              expect(body['success']).to be false
              expect(body['error']['code']).to eq('MISSING_REQUIRED_FIELD')
              expect(body['error']['details']['missing']).to include(first_required)
              # Rejected atomically — partial payload must not persist either key
              expect(InstallationConfig.where(name: required_keys)).to be_empty
            end

            it 'rejects save when a required key is omitted and unset in db' do
              payload = full_payload.reject { |k, _| k.to_s == first_required }

              post :create, params: { config_type: config_type, app_config: payload }, format: :json

              expect(response).to have_http_status(:bad_request)
              body = JSON.parse(response.body)
              expect(body['error']['details']['missing']).to include(first_required)
            end

            it 'accepts partial updates when omitted required keys already have values in db' do
              required_keys.each do |key|
                InstallationConfig.create!(name: key, serialized_value: { 'value' => "existing-#{key.downcase}" })
              end

              post :create, params: {
                config_type: config_type,
                app_config: { rest_required.first => 'updated-value' }
              }, format: :json

              expect(response).to have_http_status(:ok)
            end

            it 'accepts save when all required keys are provided' do
              post :create, params: { config_type: config_type, app_config: full_payload }, format: :json

              expect(response).to have_http_status(:ok)
              expect(InstallationConfig.find_by(name: first_required).value)
                .to eq(full_payload[first_required.to_sym])
            end
          end
        end
      end
    end
  end

  describe 'POST #test_connection' do
    context 'when not authenticated' do
      it 'returns 401' do
        post :test_connection, params: { config_type: 'smtp' }, format: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated as non-admin' do
      include_context 'authenticated non-admin'

      it 'returns unauthorized' do
        post :test_connection, params: { config_type: 'smtp' }, format: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated as admin' do
      include_context 'authenticated admin'

      context 'with unknown config type' do
        it 'returns 404' do
          post :test_connection, params: { config_type: 'nonexistent' }, format: :json

          expect(response).to have_http_status(:not_found)
          body = JSON.parse(response.body)
          expect(body['success']).to be false
        end
      end

      context 'with smtp config type and MAILER_TYPE=smtp' do
        before do
          allow(GlobalConfigService).to receive(:load).with('MAILER_TYPE', 'smtp').and_return('smtp')
          service = instance_double(ConfigTest::SmtpTestService)
          allow(ConfigTest::SmtpTestService).to receive(:new).and_return(service)
          allow(service).to receive(:call).and_return({ success: true, message: 'SMTP connection successful' })
        end

        it 'routes to SmtpTestService and returns 200' do
          post :test_connection, params: { config_type: 'smtp' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['success']).to be true
          expect(body['data']['success']).to be true
          expect(body['data']['message']).to eq('SMTP connection successful')
        end
      end

      context 'with smtp config type and MAILER_TYPE=bms' do
        before do
          allow(GlobalConfigService).to receive(:load).with('MAILER_TYPE', 'smtp').and_return('bms')
          service = instance_double(ConfigTest::BmsTestService)
          allow(ConfigTest::BmsTestService).to receive(:new).and_return(service)
          allow(service).to receive(:call).and_return({ success: true, message: 'BMS API connection successful' })
        end

        it 'routes to BmsTestService' do
          post :test_connection, params: { config_type: 'smtp' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['data']['message']).to eq('BMS API connection successful')
        end
      end

      context 'with smtp config type and MAILER_TYPE=resend' do
        before do
          allow(GlobalConfigService).to receive(:load).with('MAILER_TYPE', 'smtp').and_return('resend')
          service = instance_double(ConfigTest::ResendTestService)
          allow(ConfigTest::ResendTestService).to receive(:new).and_return(service)
          allow(service).to receive(:call).and_return({ success: true, message: 'Resend API connection successful' })
        end

        it 'routes to ResendTestService' do
          post :test_connection, params: { config_type: 'smtp' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['data']['message']).to eq('Resend API connection successful')
        end
      end

      context 'when connection test fails' do
        before do
          allow(GlobalConfigService).to receive(:load).with('MAILER_TYPE', 'smtp').and_return('smtp')
          service = instance_double(ConfigTest::SmtpTestService)
          allow(ConfigTest::SmtpTestService).to receive(:new).and_return(service)
          allow(service).to receive(:call).and_return({ success: false, message: 'Connection refused — check server address and port' })
        end

        it 'returns 200 with success: false in body' do
          post :test_connection, params: { config_type: 'smtp' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['data']['success']).to be false
          expect(body['data']['message']).to include('Connection refused')
        end
      end

      context 'with storage config type' do
        before do
          service = instance_double(ConfigTest::StorageTestService)
          allow(ConfigTest::StorageTestService).to receive(:new).and_return(service)
          allow(service).to receive(:call).and_return({ success: true, message: 'Storage connection successful' })
        end

        it 'routes to StorageTestService and returns 200' do
          post :test_connection, params: { config_type: 'storage' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['data']['success']).to be true
          expect(body['data']['message']).to eq('Storage connection successful')
        end
      end


      context 'with unsupported config type for testing' do
        it 'returns unsupported message' do
          post :test_connection, params: { config_type: 'evolution' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['data']['success']).to be false
          expect(body['data']['message']).to include('not supported')
        end
      end
    end
  end
end
