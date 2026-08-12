require 'rails_helper'
require 'aws-sdk-s3'

RSpec.describe ConfigTest::StorageTestService do
  subject { described_class.new.call }

  before do
    allow(GlobalConfigService).to receive(:load_env_first).and_call_original
  end

  describe '#call' do
    context 'when storage service is local' do
      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('local')
      end

      it 'returns immediate success' do
        expect(subject).to eq({ success: true, message: 'Local storage is always available' })
      end

      it 'does not create an S3 client' do
        expect(Aws::S3::Client).not_to receive(:new)
        subject
      end
    end

    context 'when bucket name is not configured' do
      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('s3_compatible')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return(nil)
      end

      it 'returns failure with bucket not configured message' do
        expect(subject).to eq({ success: false, message: 'Bucket name not configured' })
      end
    end

    context 'when S3 connection succeeds' do
      let(:s3_client) { instance_double(Aws::S3::Client) }

      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('s3_compatible')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return('my-bucket')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_KEY_ID', any_args).and_return('AKIA12345')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_SECRET', any_args).and_return('secret-key')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_REGION', any_args).and_return('us-east-1')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ENDPOINT', any_args).and_return('https://s3.example.com')
        allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
        allow(s3_client).to receive(:head_bucket).and_return(true)
      end

      it 'returns success' do
        expect(subject).to eq({ success: true, message: 'Storage connection successful' })
      end

      it 'creates S3 client with correct options' do
        expect(Aws::S3::Client).to receive(:new).with(hash_including(
                                                         access_key_id: 'AKIA12345',
                                                         secret_access_key: 'secret-key',
                                                         region: 'us-east-1',
                                                         endpoint: 'https://s3.example.com',
                                                         http_open_timeout: 15,
                                                         http_read_timeout: 15
                                                       )).and_return(s3_client)
        allow(s3_client).to receive(:head_bucket)
        subject
      end

      it 'calls head_bucket with the configured bucket' do
        expect(s3_client).to receive(:head_bucket).with(bucket: 'my-bucket')
        subject
      end
    end

    context 'when S3 connection succeeds without custom endpoint' do
      let(:s3_client) { instance_double(Aws::S3::Client) }

      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('amazon')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return('my-bucket')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_KEY_ID', any_args).and_return('AKIA12345')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_SECRET', any_args).and_return('secret-key')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_REGION', any_args).and_return('us-east-1')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ENDPOINT', any_args).and_return(nil)
        allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
        allow(s3_client).to receive(:head_bucket).and_return(true)
      end

      it 'does not include endpoint but still includes force_path_style' do
        expect(Aws::S3::Client).to receive(:new) do |opts|
          expect(opts).to include(force_path_style: true)
          expect(opts).not_to have_key(:endpoint)
          s3_client
        end
        allow(s3_client).to receive(:head_bucket)
        subject
      end
    end

    context 'when access key is blank' do
      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('s3_compatible')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return('my-bucket')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_KEY_ID', any_args).and_return(nil)
      end

      it 'returns failure with access key not configured message' do
        expect(subject).to eq({ success: false, message: 'Access Key ID not configured' })
      end

      it 'does not create an S3 client' do
        expect(Aws::S3::Client).not_to receive(:new)
        subject
      end
    end

    context 'when secret key is blank' do
      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('s3_compatible')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return('my-bucket')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_KEY_ID', any_args).and_return('AKIA12345')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_SECRET', any_args).and_return('')
      end

      it 'returns failure with secret key not configured message' do
        expect(subject).to eq({ success: false, message: 'Secret Access Key not configured' })
      end

      it 'does not create an S3 client' do
        expect(Aws::S3::Client).not_to receive(:new)
        subject
      end
    end

    context 'when access is denied' do
      let(:s3_client) { instance_double(Aws::S3::Client) }

      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('s3_compatible')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return('my-bucket')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_KEY_ID', any_args).and_return('bad-key')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_SECRET', any_args).and_return('bad-secret')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_REGION', any_args).and_return('us-east-1')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ENDPOINT', any_args).and_return(nil)
        allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
        allow(s3_client).to receive(:head_bucket).and_raise(
          Aws::S3::Errors::Forbidden.new(nil, 'Access Denied')
        )
      end

      it 'returns failure with access denied message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Access denied')
      end
    end

    context 'when bucket is not found' do
      let(:s3_client) { instance_double(Aws::S3::Client) }

      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('s3_compatible')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return('nonexistent-bucket')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_KEY_ID', any_args).and_return('key')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_SECRET', any_args).and_return('secret')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_REGION', any_args).and_return('us-east-1')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ENDPOINT', any_args).and_return(nil)
        allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
        allow(s3_client).to receive(:head_bucket).and_raise(
          Aws::S3::Errors::NotFound.new(nil, 'Not Found')
        )
      end

      it 'returns failure with bucket not found message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Bucket not found')
      end
    end

    context 'when connection times out' do
      let(:s3_client) { instance_double(Aws::S3::Client) }

      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('s3_compatible')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return('my-bucket')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_KEY_ID', any_args).and_return('key')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_SECRET', any_args).and_return('secret')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_REGION', any_args).and_return('us-east-1')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ENDPOINT', any_args).and_return(nil)
        allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
        allow(s3_client).to receive(:head_bucket).and_raise(Timeout::Error)
      end

      it 'returns failure with timeout message' do
        expect(subject).to eq({ success: false, message: 'Connection timed out after 15 seconds' })
      end
    end

    context 'when a network error occurs' do
      let(:s3_client) { instance_double(Aws::S3::Client) }

      before do
        allow(GlobalConfigService).to receive(:load_env_first).with('ACTIVE_STORAGE_SERVICE', any_args).and_return('s3_compatible')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return('my-bucket')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_KEY_ID', any_args).and_return('key')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ACCESS_SECRET', any_args).and_return('secret')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_REGION', any_args).and_return('us-east-1')
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_ENDPOINT', any_args).and_return(nil)
        allow(Aws::S3::Client).to receive(:new).and_return(s3_client)
        allow(s3_client).to receive(:head_bucket).and_raise(StandardError.new('getaddrinfo: Name or service not known'))
      end

      it 'returns failure with connection error message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Connection failed')
      end
    end

    context 'when the ENV and the installation_config disagree' do
      around do |example|
        saved = ENV.fetch('ACTIVE_STORAGE_SERVICE', nil)
        example.run
      ensure
        saved.nil? ? ENV.delete('ACTIVE_STORAGE_SERVICE') : (ENV['ACTIVE_STORAGE_SERVICE'] = saved)
      end

      it 'probes the ENV provider instead of shortcutting on the stale DB value' do
        ENV['ACTIVE_STORAGE_SERVICE'] = 's3_compatible'
        allow(GlobalConfig).to receive(:get).with('ACTIVE_STORAGE_SERVICE').and_return(
          { 'ACTIVE_STORAGE_SERVICE' => 'local' }.with_indifferent_access
        )
        allow(GlobalConfigService).to receive(:load_env_first).with('STORAGE_BUCKET_NAME', any_args).and_return(nil)

        expect(subject).to eq({ success: false, message: 'Bucket name not configured' })
      end
    end

    context 'timeout configuration' do
      it 'sets 15-second timeout' do
        expect(described_class::TIMEOUT).to eq(15)
      end
    end
  end
end
