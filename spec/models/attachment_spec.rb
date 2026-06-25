# frozen_string_literal: true

# Regression spec for Attachment#file_url and Attachment#thumb_url honoring
# ENV['ACTIVE_STORAGE_URL'] via the BlobUrlOptions concern (EVO-1747).
#
# Default Rails test url_options point to localhost:3000; with ACTIVE_STORAGE_URL
# set, the generated URL must use the override host/port/protocol so the browser
# can reach the file when DiskService is in use.

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Attachment URL options' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails) && defined?(ActiveStorage::Blob)

RSpec.describe Attachment, type: :model do
  let(:attachment) { Attachment.new(file_type: :image) }

  # Captures whatever ActiveStorage::Current.url_options was at the moment
  # url_for was invoked, so we can assert the override was scoped to the call.
  def stub_url_for_capturing_options(return_value)
    captured = {}
    allow(attachment).to receive(:url_for) do |_arg|
      captured.merge!(ActiveStorage::Current.url_options || {})
      return_value
    end
    captured
  end

  describe '#file_url' do
    context 'when file is not attached' do
      it 'returns an empty string' do
        expect(attachment.file_url).to eq('')
      end
    end

    context 'when file is attached' do
      let(:file_proxy) { instance_double('ActiveStorage::Attached::One', attached?: true) }

      before { allow(attachment).to receive(:file).and_return(file_proxy) }

      it "uses default_url_options when ENV['ACTIVE_STORAGE_URL'] is blank" do
        ENV['ACTIVE_STORAGE_URL'] = nil
        captured = stub_url_for_capturing_options('http://localhost:3000/rails/active_storage/blobs/test')
        attachment.file_url
        expect(captured[:host]).to eq(Rails.application.routes.default_url_options[:host])
      end

      it 'uses ACTIVE_STORAGE_URL host/port/protocol when set' do
        ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
        captured = stub_url_for_capturing_options('https://media.example.com:8443/rails/active_storage/blobs/test')
        attachment.file_url
        expect(captured).to include(host: 'media.example.com', port: 8443, protocol: 'https')
      ensure
        ENV['ACTIVE_STORAGE_URL'] = nil
      end

      it 'restores previous ActiveStorage::Current.url_options after the call' do
        previous = { host: 'previous.example.com', port: 9000, protocol: 'http' }
        ActiveStorage::Current.url_options = previous
        ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
        allow(attachment).to receive(:url_for).and_return('ignored')
        attachment.file_url
        expect(ActiveStorage::Current.url_options).to eq(previous)
      ensure
        ENV['ACTIVE_STORAGE_URL'] = nil
        ActiveStorage::Current.url_options = nil
      end

      # Regression guard: the previous implementation called url_for(file, **opts)
      # which raised ArgumentError ("wrong number of arguments (given 2, expected 0..1)")
      # at runtime because url_for has arity 0..1. Any future refactor that
      # reintroduces extra positional/keyword arguments must break this spec.
      it 'invokes url_for with exactly one positional argument and no kwargs (arity guard)' do
        captured = { positional: [], kwargs: {} }
        allow(attachment).to receive(:url_for) do |*args, **kwargs|
          captured[:positional] = args
          captured[:kwargs] = kwargs
          'http://example/x'
        end
        attachment.file_url
        expect(captured[:positional].size).to eq(1)
        expect(captured[:kwargs]).to be_empty
      end
    end
  end

  describe '#download_url' do
    context 'when file is not attached' do
      it 'returns an empty string' do
        allow(attachment).to receive(:file).and_return(double('file', attached?: false))
        expect(attachment.download_url).to eq('')
      end
    end

    context 'when file is attached' do
      let(:blob) { double('blob') }
      let(:file_proxy) { double('file', attached?: true, blob: blob) }

      before { allow(attachment).to receive(:file).and_return(file_proxy) }

      it 'invokes blob.url under scoped ActiveStorage::Current.url_options with ACTIVE_STORAGE_URL' do
        ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
        captured = {}
        allow(blob).to receive(:url) do
          captured.merge!(ActiveStorage::Current.url_options || {})
          'https://media.example.com:8443/rails/active_storage/disk/signed'
        end
        attachment.download_url
        expect(captured).to include(host: 'media.example.com', port: 8443, protocol: 'https')
      ensure
        ENV['ACTIVE_STORAGE_URL'] = nil
      end

      it 'restores previous ActiveStorage::Current.url_options after the call' do
        previous = { host: 'previous.example.com', port: 9000, protocol: 'http' }
        ActiveStorage::Current.url_options = previous
        ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
        allow(blob).to receive(:url).and_return('ignored')
        attachment.download_url
        expect(ActiveStorage::Current.url_options).to eq(previous)
      ensure
        ENV['ACTIVE_STORAGE_URL'] = nil
        ActiveStorage::Current.url_options = nil
      end
    end
  end

  describe '#thumb_url' do
    context 'when file is not attached or not representable' do
      it 'returns an empty string when not attached' do
        # NOTE: representable? is delegated via method_missing on Attached::One,
        # so instance_double rejects it — use a plain double for these proxies.
        allow(attachment).to receive(:file).and_return(double('file', attached?: false, representable?: false))
        expect(attachment.thumb_url).to eq('')
      end
    end

    context 'when file is attached and representable' do
      let(:representation) { double('representation') }
      let(:file_proxy) do
        double('file', attached?: true, representable?: true, representation: representation)
      end

      before { allow(attachment).to receive(:file).and_return(file_proxy) }

      it "uses default_url_options when ENV['ACTIVE_STORAGE_URL'] is blank" do
        ENV['ACTIVE_STORAGE_URL'] = nil
        captured = {}
        expect(attachment).to receive(:url_for) do |arg|
          expect(arg).to eq(representation)
          captured.merge!(ActiveStorage::Current.url_options || {})
          'http://localhost:3000/rails/active_storage/representations/test'
        end
        attachment.thumb_url
        expect(captured[:host]).to eq(Rails.application.routes.default_url_options[:host])
      end

      it 'uses ACTIVE_STORAGE_URL host/port/protocol when set' do
        ENV['ACTIVE_STORAGE_URL'] = 'https://media.example.com:8443'
        captured = {}
        expect(attachment).to receive(:url_for) do |arg|
          expect(arg).to eq(representation)
          captured.merge!(ActiveStorage::Current.url_options || {})
          'https://media.example.com:8443/rails/active_storage/representations/test'
        end
        attachment.thumb_url
        expect(captured).to include(host: 'media.example.com', port: 8443, protocol: 'https')
      ensure
        ENV['ACTIVE_STORAGE_URL'] = nil
      end

      # Same arity guard as #file_url — see comment above.
      it 'invokes url_for with exactly one positional argument and no kwargs (arity guard)' do
        captured = { positional: [], kwargs: {} }
        allow(attachment).to receive(:url_for) do |*args, **kwargs|
          captured[:positional] = args
          captured[:kwargs] = kwargs
          'http://example/x'
        end
        attachment.thumb_url
        expect(captured[:positional].size).to eq(1)
        expect(captured[:kwargs]).to be_empty
      end
    end
  end
end
