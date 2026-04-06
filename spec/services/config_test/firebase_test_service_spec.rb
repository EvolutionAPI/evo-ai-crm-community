require 'rails_helper'
require 'googleauth'

RSpec.describe ConfigTest::FirebaseTestService do
  subject { described_class.new.call }

  let(:valid_credentials) do
    {
      'project_id' => 'my-firebase-project',
      'client_email' => 'firebase-adminsdk@my-firebase-project.iam.gserviceaccount.com',
      'private_key' => "-----BEGIN RSA PRIVATE KEY-----\nMIIBogIBAAJBAL...\n-----END RSA PRIVATE KEY-----\n",
      'type' => 'service_account'
    }
  end

  let(:valid_credentials_json) { valid_credentials.to_json }

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
  end

  describe '#call' do
    context 'when credentials are not configured' do
      before do
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return(nil)
      end

      it 'returns failure with not configured message' do
        expect(subject).to eq({ success: false, message: 'Firebase credentials not configured' })
      end
    end

    context 'when credentials JSON is blank' do
      before do
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return('')
      end

      it 'returns failure with not configured message' do
        expect(subject).to eq({ success: false, message: 'Firebase credentials not configured' })
      end
    end

    context 'when credentials JSON is invalid' do
      before do
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return('not-valid-json{')
      end

      it 'returns failure with invalid JSON message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to start_with('Invalid JSON:')
      end
    end

    context 'when required fields are missing' do
      before do
        incomplete = { 'project_id' => 'my-project' }.to_json
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return(incomplete)
      end

      it 'returns failure listing missing fields' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Missing required fields')
        expect(subject[:message]).to include('client_email')
        expect(subject[:message]).to include('private_key')
      end
    end

    context 'when project_id does not match configured FIREBASE_PROJECT_ID' do
      before do
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return(valid_credentials_json)
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return('different-project')
      end

      it 'returns failure with mismatch message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include("doesn't match configured FIREBASE_PROJECT_ID")
        expect(subject[:message]).to include('my-firebase-project')
        expect(subject[:message]).to include('different-project')
      end
    end

    context 'when credentials are valid and authentication succeeds' do
      let(:authorizer) { instance_double(Google::Auth::ServiceAccountCredentials) }

      before do
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return(valid_credentials_json)
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return('my-firebase-project')
        allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(authorizer)
        allow(authorizer).to receive(:fetch_access_token!).and_return({ 'access_token' => 'token' })
      end

      it 'returns success' do
        expect(subject).to eq({ success: true, message: 'Firebase credentials valid' })
      end

      it 'creates credentials with correct scope' do
        expect(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).with(
          hash_including(scope: 'https://www.googleapis.com/auth/firebase.messaging')
        ).and_return(authorizer)
        allow(authorizer).to receive(:fetch_access_token!)
        subject
      end
    end

    context 'when FIREBASE_PROJECT_ID is not configured' do
      let(:authorizer) { instance_double(Google::Auth::ServiceAccountCredentials) }

      before do
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return(valid_credentials_json)
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return(nil)
        allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(authorizer)
        allow(authorizer).to receive(:fetch_access_token!).and_return({ 'access_token' => 'token' })
      end

      it 'skips project_id validation and returns success' do
        expect(subject).to eq({ success: true, message: 'Firebase credentials valid' })
      end
    end

    context 'when authentication fails' do
      before do
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return(valid_credentials_json)
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return(nil)
        allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_raise(
          Signet::AuthorizationError.new('invalid_grant: Invalid JWT')
        )
      end

      it 'returns failure with authentication error message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Firebase authentication failed')
      end
    end

    context 'when connection times out' do
      let(:authorizer) { instance_double(Google::Auth::ServiceAccountCredentials) }

      before do
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return(valid_credentials_json)
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return(nil)
        allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_return(authorizer)
        allow(authorizer).to receive(:fetch_access_token!).and_raise(Timeout::Error)
      end

      it 'returns failure with timeout message' do
        expect(subject).to eq({ success: false, message: 'Firebase validation timed out after 15 seconds' })
      end
    end

    context 'when an unexpected error occurs' do
      before do
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_CREDENTIALS_SECRET', nil).and_return(valid_credentials_json)
        allow(GlobalConfigService).to receive(:load).with('FIREBASE_PROJECT_ID', nil).and_return(nil)
        allow(Google::Auth::ServiceAccountCredentials).to receive(:make_creds).and_raise(
          StandardError.new('getaddrinfo: Name or service not known')
        )
      end

      it 'returns failure with generic error message' do
        expect(subject[:success]).to be false
        expect(subject[:message]).to include('Firebase validation failed')
      end
    end

    context 'timeout configuration' do
      it 'sets 15-second timeout' do
        expect(described_class::TIMEOUT).to eq(15)
      end
    end
  end
end
