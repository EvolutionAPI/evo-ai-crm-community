require 'rails_helper'

RSpec.describe BlobUrlOptions do
  describe '.effective_url_options' do
    let(:base) { { host: 'crm.local', port: 3000, protocol: 'http' } }

    context "when ENV['ACTIVE_STORAGE_URL'] is blank" do
      around do |example|
        original = ENV['ACTIVE_STORAGE_URL']
        ENV['ACTIVE_STORAGE_URL'] = nil
        example.run
        ENV['ACTIVE_STORAGE_URL'] = original
      end

      it 'returns the base options unchanged when ENV is nil' do
        expect(described_class.effective_url_options(base)).to eq(base)
      end

      it 'returns the base options unchanged when ENV is empty string' do
        ENV['ACTIVE_STORAGE_URL'] = ''
        expect(described_class.effective_url_options(base)).to eq(base)
      end

      it 'does not mutate the base hash passed in' do
        described_class.effective_url_options(base).merge!(host: 'mutated.local')
        expect(base[:host]).to eq('crm.local')
      end
    end

    context "when ENV['ACTIVE_STORAGE_URL'] is set" do
      around do |example|
        original = ENV['ACTIVE_STORAGE_URL']
        ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
        example.run
        ENV['ACTIVE_STORAGE_URL'] = original
      end

      it 'overrides host, port and protocol from the parsed URL' do
        result = described_class.effective_url_options(base)
        expect(result).to include(host: 'media.example.com', port: 8443, protocol: 'https')
      end

      it 'preserves non-conflicting keys from the base hash' do
        base_with_extra = base.merge(script_name: '/prefix')
        result = described_class.effective_url_options(base_with_extra)
        expect(result[:script_name]).to eq('/prefix')
      end
    end

    context "when ENV['ACTIVE_STORAGE_URL'] is malformed" do
      around do |example|
        original = ENV['ACTIVE_STORAGE_URL']
        ENV['ACTIVE_STORAGE_URL'] = 'garbage://[invalid'
        example.run
        ENV['ACTIVE_STORAGE_URL'] = original
      end

      it 'logs a warning and falls back to the base options instead of raising' do
        allow(Rails.logger).to receive(:warn)
        result = nil
        expect { result = described_class.effective_url_options(base) }.not_to raise_error
        expect(result).to eq(base)
        expect(Rails.logger).to have_received(:warn).with(/Invalid ACTIVE_STORAGE_URL/)
      end
    end
  end

  describe '.with_scoped_url_options' do
    around do |example|
      original_env = ENV['ACTIVE_STORAGE_URL']
      original_current = ActiveStorage::Current.url_options
      example.run
      ENV['ACTIVE_STORAGE_URL'] = original_env
      ActiveStorage::Current.url_options = original_current
    end

    it 'sets ActiveStorage::Current.url_options for the duration of the block' do
      ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
      inside = nil
      described_class.with_scoped_url_options { inside = ActiveStorage::Current.url_options.dup }
      expect(inside).to include(host: 'media.example.com', port: 8443, protocol: 'https')
    end

    it 'restores the previous ActiveStorage::Current.url_options after the block' do
      previous = { host: 'previous.example.com', port: 9000, protocol: 'http' }
      ActiveStorage::Current.url_options = previous
      ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
      described_class.with_scoped_url_options { :noop }
      expect(ActiveStorage::Current.url_options).to eq(previous)
    end

    it 'restores even when the block raises' do
      previous = { host: 'previous.example.com', port: 9000, protocol: 'http' }
      ActiveStorage::Current.url_options = previous
      ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
      expect { described_class.with_scoped_url_options { raise 'boom' } }.to raise_error('boom')
      expect(ActiveStorage::Current.url_options).to eq(previous)
    end

    it 'returns the value of the block' do
      ENV['ACTIVE_STORAGE_URL'] = nil
      result = described_class.with_scoped_url_options { 'computed-url' }
      expect(result).to eq('computed-url')
    end
  end
end
