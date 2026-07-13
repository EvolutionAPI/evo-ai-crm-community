# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GlobalConfigService do
  # GlobalConfig.get(key) returns { key => value }; a nil value means "not set".
  def stub_db(key, value)
    allow(GlobalConfig).to receive(:get).with(key).and_return({ key => value })
  end

  describe '.load (DB-first — legacy precedence)' do
    it 'prefers the DB value over the ENV' do
      stub_db('K', 'from_db')
      ENV['K'] = 'from_env'
      expect(described_class.load('K', 'default')).to eq('from_db')
    ensure
      ENV.delete('K')
    end

    it 'falls back to the ENV when the DB value is absent' do
      stub_db('K', nil)
      ENV['K'] = 'from_env'
      expect(described_class.load('K', 'default')).to eq('from_env')
    ensure
      ENV.delete('K')
    end

    it 'returns the default when neither DB nor ENV is set' do
      stub_db('K', nil)
      expect(described_class.load('K', 'default')).to eq('default')
    end
  end

  describe '.load_env_first (ENV-first — EVO-2095)' do
    it 'prefers the ENV over the DB value (opposite of .load)' do
      stub_db('K', 'from_db')
      ENV['K'] = 'from_env'
      expect(described_class.load_env_first('K', 'default')).to eq('from_env')
    ensure
      ENV.delete('K')
    end

    it 'falls back to the DB value when the ENV is unset (admin-UI installs)' do
      stub_db('K', 'from_db')
      ENV.delete('K')
      expect(described_class.load_env_first('K', 'default')).to eq('from_db')
    end

    it 'treats a blank ENV as unset and falls back to the DB' do
      stub_db('K', 'from_db')
      ENV['K'] = ''
      expect(described_class.load_env_first('K', 'default')).to eq('from_db')
    ensure
      ENV.delete('K')
    end

    it 'returns the default when neither ENV nor DB is set' do
      stub_db('K', nil)
      ENV.delete('K')
      expect(described_class.load_env_first('K', 'default')).to eq('default')
    end

    it 'honours a distinct env_key (S3 secret: ENV STORAGE_SECRET_ACCESS_KEY vs DB STORAGE_ACCESS_SECRET)' do
      stub_db('STORAGE_ACCESS_SECRET', 'db_secret')
      ENV['STORAGE_SECRET_ACCESS_KEY'] = 'env_secret'
      result = described_class.load_env_first('STORAGE_ACCESS_SECRET', '', env_key: 'STORAGE_SECRET_ACCESS_KEY')
      expect(result).to eq('env_secret')
    ensure
      ENV.delete('STORAGE_SECRET_ACCESS_KEY')
    end

    it 'is resilient when the DB is unavailable at boot (returns ENV/default)' do
      allow(GlobalConfig).to receive(:get).and_raise(ActiveRecord::ActiveRecordError)
      ENV['K'] = 'from_env'
      expect(described_class.load_env_first('K', 'default')).to eq('from_env')
    ensure
      ENV.delete('K')
    end
  end
end
