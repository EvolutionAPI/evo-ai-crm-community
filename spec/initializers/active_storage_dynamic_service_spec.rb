# frozen_string_literal: true

require 'rails_helper'

# EVO-1961: the dynamic service resolver must keep the CRM usable when a
# bucket-backed provider is selected but not fully configured. Instead of
# letting aws-sdk raise on every request (which is what makes self-hosted
# stacks unusable without S3), we fall back to :local and warn.
RSpec.describe 'ActiveStorage dynamic service resolver' do
  around do |example|
    saved_env = %w[
      ACTIVE_STORAGE_SERVICE STORAGE_BUCKET_NAME S3_BUCKET_NAME
      GCS_BUCKET AZURE_STORAGE_CONTAINER
    ].to_h { |k| [k, ENV[k]] }
    example.run
  ensure
    saved_env.each { |k, v| v.nil? ? ENV.delete(k) : (ENV[k] = v) }
  end

  before do
    allow(GlobalConfigService).to receive(:load_env_first) do |key, default|
      ENV.fetch(key.to_s, default)
    end

    # Reset the hot-path warn dedupe so each example observes warns cleanly,
    # independent of ordering or state leaked from other specs.
    ActiveStorage::Blob.instance_variable_set(:@warned_bucket_fallback, nil)
  end

  describe 'bucket-backed fallback (AC4)' do
    it 'falls back to :local when s3_compatible is selected but STORAGE_BUCKET_NAME is blank' do
      ENV['ACTIVE_STORAGE_SERVICE'] = 's3_compatible'
      ENV['STORAGE_BUCKET_NAME'] = ''

      expect(Rails.logger).to receive(:warn).with(/'s3_compatible' selected but bucket not configured/)
      expect(ActiveStorage::Blob.service).to eq(ActiveStorage::Blob.services.fetch(:local))
    end

    it 'falls back to :local when amazon is selected but S3_BUCKET_NAME is blank' do
      ENV['ACTIVE_STORAGE_SERVICE'] = 'amazon'
      ENV['S3_BUCKET_NAME'] = nil
      ENV['STORAGE_BUCKET_NAME'] = nil

      expect(Rails.logger).to receive(:warn).with(/'amazon' selected but bucket not configured/)
      expect(ActiveStorage::Blob.service).to eq(ActiveStorage::Blob.services.fetch(:local))
    end

    it 'falls back to :local when google is selected but GCS_BUCKET is blank' do
      ENV['ACTIVE_STORAGE_SERVICE'] = 'google'
      ENV['GCS_BUCKET'] = nil
      # A stray STORAGE_BUCKET_NAME must NOT count as a configured GCS bucket
      # (regression guard: the old code checked the wrong key).
      ENV['STORAGE_BUCKET_NAME'] = 'stray-value-should-be-ignored'

      expect(Rails.logger).to receive(:warn).with(/'google' selected but bucket not configured/)
      expect(ActiveStorage::Blob.service).to eq(ActiveStorage::Blob.services.fetch(:local))
    end

    it 'falls back to :local when microsoft is selected but AZURE_STORAGE_CONTAINER is blank' do
      ENV['ACTIVE_STORAGE_SERVICE'] = 'microsoft'
      ENV['AZURE_STORAGE_CONTAINER'] = nil
      # Same regression guard for Azure's container key.
      ENV['STORAGE_BUCKET_NAME'] = 'stray-value-should-be-ignored'

      expect(Rails.logger).to receive(:warn).with(/'microsoft' selected but bucket not configured/)
      expect(ActiveStorage::Blob.service).to eq(ActiveStorage::Blob.services.fetch(:local))
    end

    it 'keeps s3_compatible when bucket is configured (does not fall back)' do
      ENV['ACTIVE_STORAGE_SERVICE'] = 's3_compatible'
      ENV['STORAGE_BUCKET_NAME'] = 'my-bucket'

      # Stub the registry so we don't lazy-build a real S3 client at test time.
      fake_s3 = instance_double(ActiveStorage::Service, name: :s3_compatible)
      allow(ActiveStorage::Blob.services).to receive(:fetch).with(:s3_compatible).and_return(fake_s3)

      expect(Rails.logger).not_to receive(:warn).with(/bucket not configured/)
      expect(ActiveStorage::Blob.service.name).to eq(:s3_compatible)
    end

    it 'keeps google when GCS_BUCKET is configured (does not fall back)' do
      ENV['ACTIVE_STORAGE_SERVICE'] = 'google'
      ENV['GCS_BUCKET'] = 'my-gcs-bucket'
      ENV['STORAGE_BUCKET_NAME'] = nil

      # Stub the registry so we don't lazy-build a real GCS client at test time.
      fake_gcs = instance_double(ActiveStorage::Service, name: :google)
      allow(ActiveStorage::Blob.services).to receive(:fetch).with(:google).and_return(fake_gcs)

      expect(Rails.logger).not_to receive(:warn).with(/bucket not configured/)
      expect(ActiveStorage::Blob.service.name).to eq(:google)
    end
  end

  describe ':local as the default (AC1)' do
    it 'resolves :local when ACTIVE_STORAGE_SERVICE is unset' do
      ENV['ACTIVE_STORAGE_SERVICE'] = nil

      expect(ActiveStorage::Blob.service).to eq(ActiveStorage::Blob.services.fetch(:local))
    end
  end

  describe 'ENV wins over a stale DB installation_config (DB-over-ENV guard)' do
    it 'resolves the ENV provider even when installation_configs says :local' do
      ENV['ACTIVE_STORAGE_SERVICE'] = 's3_compatible'
      ENV['STORAGE_BUCKET_NAME'] = 'my-bucket'

      # The installation_configs row stays stale; the ENV must win without it being read.
      allow(GlobalConfigService).to receive(:load_env_first).and_call_original
      allow(GlobalConfig).to receive(:get).with('ACTIVE_STORAGE_SERVICE').and_return(
        { 'ACTIVE_STORAGE_SERVICE' => 'local' }.with_indifferent_access
      )

      fake_s3 = instance_double(ActiveStorage::Service, name: :s3_compatible)
      allow(ActiveStorage::Blob.services).to receive(:fetch).with(:s3_compatible).and_return(fake_s3)

      expect(ActiveStorage::Blob.service.name).to eq(:s3_compatible)
    end
  end
end
