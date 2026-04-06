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
  end

  after do
    Current.reset
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
          expect(configs['SMTP_PASSWORD_SECRET']).to start_with('••••••••')
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
          expect(configs['STORAGE_ACCESS_SECRET']).to start_with('••••••••')
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

      context 'with stripe_payments config type' do
        before do
          InstallationConfig.create!(name: 'STRIPE_PUBLISHABLE_KEY', serialized_value: { 'value' => 'pk_test_abc123' })
          InstallationConfig.create!(name: 'STRIPE_KEY_SECRET', serialized_value: { 'value' => 'sk_test_secret123' })
          InstallationConfig.create!(name: 'STRIPE_WEBHOOK_SECRET', serialized_value: { 'value' => 'whsec_secret456' })
        end

        it 'returns all 3 stripe keys' do
          get :show, params: { config_type: 'stripe_payments' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          configs = body['data']['configs']
          expected_keys = %w[STRIPE_KEY_SECRET STRIPE_PUBLISHABLE_KEY STRIPE_WEBHOOK_SECRET]
          expect(configs.keys).to match_array(expected_keys)
        end

        it 'masks STRIPE_KEY_SECRET and STRIPE_WEBHOOK_SECRET' do
          get :show, params: { config_type: 'stripe_payments' }, format: :json

          body = JSON.parse(response.body)
          configs = body['data']['configs']
          expect(configs['STRIPE_KEY_SECRET']).to start_with('••••••••')
          expect(configs['STRIPE_KEY_SECRET']).not_to eq('sk_test_secret123')
          expect(configs['STRIPE_WEBHOOK_SECRET']).to start_with('••••••••')
          expect(configs['STRIPE_WEBHOOK_SECRET']).not_to eq('whsec_secret456')
        end

        it 'returns plain value for STRIPE_PUBLISHABLE_KEY' do
          get :show, params: { config_type: 'stripe_payments' }, format: :json

          body = JSON.parse(response.body)
          configs = body['data']['configs']
          expect(configs['STRIPE_PUBLISHABLE_KEY']).to eq('pk_test_abc123')
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
            app_config: { EVOLUTION_API_URL: 'https://api.example.com' }
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

      context 'with push_notifications config type' do
        before do
          service = instance_double(ConfigTest::FirebaseTestService)
          allow(ConfigTest::FirebaseTestService).to receive(:new).and_return(service)
          allow(service).to receive(:call).and_return({ success: true, message: 'Firebase credentials valid' })
        end

        it 'routes to FirebaseTestService and returns 200' do
          post :test_connection, params: { config_type: 'push_notifications' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['data']['success']).to be true
          expect(body['data']['message']).to eq('Firebase credentials valid')
        end
      end

      context 'with push_notifications failure' do
        before do
          service = instance_double(ConfigTest::FirebaseTestService)
          allow(ConfigTest::FirebaseTestService).to receive(:new).and_return(service)
          allow(service).to receive(:call).and_return({ success: false, message: 'Firebase credentials not configured' })
        end

        it 'returns 200 with success: false in body' do
          post :test_connection, params: { config_type: 'push_notifications' }, format: :json

          expect(response).to have_http_status(:ok)
          body = JSON.parse(response.body)
          expect(body['data']['success']).to be false
          expect(body['data']['message']).to include('not configured')
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
