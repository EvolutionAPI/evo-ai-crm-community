require 'rails_helper'

RSpec.describe 'Email Configuration (Story 2.1)' do
  before do
    ENV['ENCRYPTION_KEY'] = 'test-encryption-key-for-fernet!!'
    InstallationConfig.reset_encryption_key_cache!
    # Wipe configs that this spec asserts on so pre-seeded rows in the test
    # DB don't collide with `create!` calls inside the examples.
    InstallationConfig.where(name: %w[
      MAILER_TYPE SMTP_ADDRESS SMTP_PORT SMTP_USERNAME SMTP_PASSWORD_SECRET
      MAILER_SENDER_EMAIL RESEND_API_SECRET BMS_API_SECRET
    ]).delete_all
    # Stub Redis to avoid cache pollution between tests
    redis_double = double('redis')
    allow($alfred).to receive(:with).and_yield(redis_double)
    allow(redis_double).to receive(:get).and_return(nil)
    allow(redis_double).to receive(:set).and_return(true)
    allow(redis_double).to receive(:del).and_return(true)
    allow(redis_double).to receive(:keys).and_return([])
    allow(redis_double).to receive(:expire).and_return(true)
  end

  describe 'installation_config.yml SMTP keys' do
    let(:yaml_path) { Rails.root.join('config/installation_config.yml') }
    let(:yaml_configs) { YAML.load_file(yaml_path) }
    let(:config_names) { yaml_configs.map { |c| c['name'] } }

    let(:expected_smtp_keys) do
      %w[
        SMTP_ADDRESS SMTP_PORT SMTP_USERNAME SMTP_PASSWORD_SECRET
        SMTP_AUTHENTICATION SMTP_DOMAIN SMTP_ENABLE_STARTTLS_AUTO
        SMTP_OPENSSL_VERIFY_MODE MAILER_SENDER_EMAIL MAILER_TYPE
        RESEND_API_SECRET
      ]
    end

    it 'contains all expected SMTP-related keys' do
      expected_smtp_keys.each do |key|
        expect(config_names).to include(key), "Missing key: #{key}"
      end
    end

    it 'marks secret keys with type: secret' do
      secret_keys = %w[SMTP_PASSWORD_SECRET RESEND_API_SECRET]
      secret_keys.each do |key|
        config = yaml_configs.find { |c| c['name'] == key }
        expect(config['type']).to eq('secret'), "#{key} should have type: secret"
      end
    end

    it 'marks all SMTP keys as unlocked (locked: false)' do
      expected_smtp_keys.each do |key|
        config = yaml_configs.find { |c| c['name'] == key }
        expect(config['locked']).to eq(false), "#{key} should have locked: false"
      end
    end

    it 'sets MAILER_TYPE default value to smtp' do
      config = yaml_configs.find { |c| c['name'] == 'MAILER_TYPE' }
      expect(config['value']).to eq('smtp')
    end

    it 'sets SMTP_PORT default value to 587' do
      config = yaml_configs.find { |c| c['name'] == 'SMTP_PORT' }
      expect(config['value']).to eq('587')
    end

    it 'sets SMTP_ENABLE_STARTTLS_AUTO default to true' do
      config = yaml_configs.find { |c| c['name'] == 'SMTP_ENABLE_STARTTLS_AUTO' }
      expect(config['value']).to eq(true)
    end
  end

  describe 'GET /api/v1/admin/app_configs/smtp returns all 13 keys' do
    let(:smtp_keys) { Api::V1::Admin::AppConfigsController::CONFIG_TYPES['smtp'] }

    it 'has exactly 13 SMTP keys in CONFIG_TYPES' do
      expect(smtp_keys.length).to eq(13)
    end

    it 'includes all expected keys' do
      expected = %w[
        SMTP_ADDRESS SMTP_PORT SMTP_USERNAME SMTP_PASSWORD_SECRET
        SMTP_AUTHENTICATION SMTP_DOMAIN SMTP_ENABLE_STARTTLS_AUTO
        SMTP_OPENSSL_VERIFY_MODE MAILER_SENDER_EMAIL MAILER_TYPE
        RESEND_API_SECRET BMS_API_SECRET BMS_IPPOOL
      ]
      expect(smtp_keys).to match_array(expected)
    end
  end

  describe 'MAILER_TYPE can be saved and read' do
    before do
      InstallationConfig.create!(name: 'MAILER_TYPE', serialized_value: { 'value' => 'resend' })
    end

    it 'stores and retrieves MAILER_TYPE value' do
      config = InstallationConfig.find_by(name: 'MAILER_TYPE')
      expect(config.value).to eq('resend')
    end

    it 'can be updated to different provider type' do
      config = InstallationConfig.find_by(name: 'MAILER_TYPE')
      config.update!(serialized_value: { 'value' => 'bms' })
      expect(config.reload.value).to eq('bms')
    end
  end

  describe 'GlobalConfigService loads email settings with ENV fallback' do
    context 'when DB has a value' do
      before do
        InstallationConfig.create!(name: 'SMTP_ADDRESS', serialized_value: { 'value' => 'db-smtp.example.com' })
      end

      it 'returns DB value over ENV' do
        result = GlobalConfigService.load('SMTP_ADDRESS', 'default-smtp')
        expect(result).to eq('db-smtp.example.com')
      end
    end

    context 'when DB has no value but ENV does' do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('SMTP_ADDRESS', nil).and_return('env-smtp.example.com')
      end

      it 'falls back to ENV' do
        result = GlobalConfigService.load('SMTP_ADDRESS', 'default-smtp')
        expect(result).to eq('env-smtp.example.com')
      end
    end

    context 'when neither DB nor ENV has a value' do
      before do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('SMTP_ADDRESS', anything) { |_, default| default }
      end

      it 'returns default value' do
        result = GlobalConfigService.load('SMTP_ADDRESS', 'default-smtp')
        expect(result).to eq('default-smtp')
      end
    end
  end

  describe 'ApplicationMailer dynamic settings' do
    describe '.get_mailer_sender_email' do
      it 'returns DB value when configured' do
        InstallationConfig.create!(name: 'MAILER_SENDER_EMAIL', serialized_value: { 'value' => 'test@example.com' })
        expect(ApplicationMailer.get_mailer_sender_email).to eq('test@example.com')
      end

      it 'falls back to ENV when DB is empty' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('MAILER_SENDER_EMAIL', anything).and_return('env@example.com')
        expect(ApplicationMailer.get_mailer_sender_email).to eq('env@example.com')
      end
    end

    describe '#smtp_config_set_or_development?' do
      let(:mailer) { ApplicationMailer.new }

      it 'returns true when SMTP_ADDRESS is set in ENV' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('SMTP_ADDRESS', nil).and_return('smtp.example.com')
        expect(mailer.smtp_config_set_or_development?).to be true
      end

      it 'returns true when MAILER_TYPE is set in DB (no ENV)' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('SMTP_ADDRESS', nil).and_return(nil)
        InstallationConfig.create!(name: 'MAILER_TYPE', serialized_value: { 'value' => 'bms' })
        expect(mailer.smtp_config_set_or_development?).to be true
      end

      it 'returns true when SMTP_ADDRESS is set in DB only (no ENV)' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('SMTP_ADDRESS', nil).and_return(nil)
        InstallationConfig.create!(name: 'SMTP_ADDRESS', serialized_value: { 'value' => 'db-smtp.example.com' })
        expect(mailer.smtp_config_set_or_development?).to be true
      end

      it 'returns false when no email config is set' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('SMTP_ADDRESS', nil).and_return(nil)
        allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new('production'))
        expect(mailer.smtp_config_set_or_development?).to be false
      end
    end

    describe '#load_dynamic_mail_settings' do
      let(:mailer) { ApplicationMailer.new }

      context 'when MAILER_TYPE is smtp' do
        before do
          InstallationConfig.create!(name: 'MAILER_TYPE', serialized_value: { 'value' => 'smtp' })
          InstallationConfig.create!(name: 'SMTP_ADDRESS', serialized_value: { 'value' => 'dynamic-smtp.example.com' })
          InstallationConfig.create!(name: 'SMTP_PORT', serialized_value: { 'value' => '465' })
          InstallationConfig.create!(name: 'SMTP_USERNAME', serialized_value: { 'value' => 'user@example.com' })
        end

        it 'stores SMTP settings in instance variables (thread-safe)' do
          mailer.send(:load_dynamic_mail_settings)
          expect(mailer.instance_variable_get(:@dynamic_delivery_method)).to eq(:smtp)
          options = mailer.instance_variable_get(:@dynamic_delivery_options)
          expect(options[:address]).to eq('dynamic-smtp.example.com')
          expect(options[:port]).to eq(465)
          expect(options[:user_name]).to eq('user@example.com')
        end

        it 'converts SMTP_PORT to integer' do
          mailer.send(:load_dynamic_mail_settings)
          options = mailer.instance_variable_get(:@dynamic_delivery_options)
          expect(options[:port]).to be_a(Integer)
        end
      end

      context 'when MAILER_TYPE is bms' do
        before do
          InstallationConfig.create!(name: 'MAILER_TYPE', serialized_value: { 'value' => 'bms' })
          InstallationConfig.create!(name: 'BMS_API_SECRET', serialized_value: { 'value' => 'test-bms-key' })
        end

        it 'stores BMS delivery method in instance variable' do
          mailer.send(:load_dynamic_mail_settings)
          expect(mailer.instance_variable_get(:@dynamic_delivery_method)).to eq(:bms)
        end
      end

      context 'when MAILER_TYPE is resend' do
        before do
          InstallationConfig.create!(name: 'MAILER_TYPE', serialized_value: { 'value' => 'resend' })
          InstallationConfig.create!(name: 'RESEND_API_SECRET', serialized_value: { 'value' => 'test-resend-key' })
        end

        it 'stores Resend delivery method and API key in instance variables' do
          mailer.send(:load_dynamic_mail_settings)
          expect(mailer.instance_variable_get(:@dynamic_delivery_method)).to eq(:resend)
          expect(mailer.instance_variable_get(:@dynamic_resend_api_key)).to eq('test-resend-key')
        end
      end

      context 'when SMTP settings are loaded dynamically' do
        before do
          # Simulate boot-time SSL setting
          ApplicationMailer.smtp_settings = { ssl: true, open_timeout: 10 }
          InstallationConfig.create!(name: 'MAILER_TYPE', serialized_value: { 'value' => 'smtp' })
          InstallationConfig.create!(name: 'SMTP_ADDRESS', serialized_value: { 'value' => 'new-smtp.example.com' })
        end

        after do
          ApplicationMailer.smtp_settings = {}
        end

        it 'preserves boot-time SSL/timeout settings via merge' do
          mailer.send(:load_dynamic_mail_settings)
          options = mailer.instance_variable_get(:@dynamic_delivery_options)
          expect(options[:ssl]).to eq(true)
          expect(options[:open_timeout]).to eq(10)
          expect(options[:address]).to eq('new-smtp.example.com')
        end
      end
    end

    describe '#apply_dynamic_delivery_settings' do
      let(:mailer) { ApplicationMailer.new }
      let(:mock_message) { instance_double(Mail::Message) }

      before do
        allow(mailer).to receive(:message).and_return(mock_message)
      end

      it 'does nothing when no dynamic method is set' do
        expect(mock_message).not_to receive(:delivery_method)
        mailer.send(:apply_dynamic_delivery_settings)
      end

      it 'calls message.delivery_method with the SMTP delivery class and settings' do
        smtp_opts = { address: 'smtp.example.com', port: 587 }
        mailer.instance_variable_set(:@dynamic_delivery_method, :smtp)
        mailer.instance_variable_set(:@dynamic_delivery_options, smtp_opts)

        expected_class = ApplicationMailer.delivery_methods[:smtp]
        expect(mock_message).to receive(:delivery_method).with(expected_class, smtp_opts)
        mailer.send(:apply_dynamic_delivery_settings)
      end

      it 'calls message.delivery_method with the BMS delivery class and empty options' do
        mailer.instance_variable_set(:@dynamic_delivery_method, :bms)
        mailer.instance_variable_set(:@dynamic_delivery_options, {})

        expected_class = ApplicationMailer.delivery_methods[:bms]
        expect(mock_message).to receive(:delivery_method).with(expected_class, {})
        mailer.send(:apply_dynamic_delivery_settings)
      end

      it 'passes api_key in options and calls message.delivery_method with the Resend delivery class' do
        mailer.instance_variable_set(:@dynamic_delivery_method, :resend)
        mailer.instance_variable_set(:@dynamic_delivery_options, {})
        mailer.instance_variable_set(:@dynamic_resend_api_key, 'my-resend-key')

        expected_class = ApplicationMailer.delivery_methods[:resend]
        expect(mock_message).to receive(:delivery_method).with(expected_class, { api_key: 'my-resend-key' })
        mailer.send(:apply_dynamic_delivery_settings)
      end
    end
  end
end
