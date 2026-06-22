# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::ErpAdapters do
  let(:dummy_klass) do
    Class.new do
      def to_bulk_params(payload)
        { products: payload['products'] || [] }
      end
    end
  end

  # `described_class.clear!` would resolve to the inner described class
  # inside the nested describes below (MappingError / Base / NoopAdapter)
  # and blow up with NoMethodError. Reference the module by name, and
  # restore `:noop` after every example so the request specs in
  # spec/requests/api/v1/webhooks/erp_spec.rb still find it.
  before { Webhooks::ErpAdapters.clear! }
  after do
    Webhooks::ErpAdapters.clear!
    Webhooks::ErpAdapters.register(:noop, Webhooks::ErpAdapters::NoopAdapter)
  end

  describe '.register / .lookup / .registered?' do
    it 'stores and retrieves an adapter under a symbol key' do
      described_class.register(:foo, dummy_klass)

      expect(described_class.lookup(:foo)).to eq(dummy_klass)
      expect(described_class.registered?(:foo)).to be(true)
    end

    it 'returns nil and false for unknown keys' do
      expect(described_class.lookup(:bar)).to be_nil
      expect(described_class.registered?(:bar)).to be(false)
    end

    it 'normalises String and Symbol keys interchangeably' do
      described_class.register('foo', dummy_klass)

      expect(described_class.lookup(:foo)).to eq(dummy_klass)
      expect(described_class.lookup('foo')).to eq(dummy_klass)
    end

    it 'treats nil key as unknown without raising' do
      expect(described_class.lookup(nil)).to be_nil
      expect(described_class.registered?(nil)).to be(false)
    end

    it 'overwrites a previously registered adapter on re-register' do
      other_klass = Class.new
      described_class.register(:foo, dummy_klass)
      described_class.register(:foo, other_klass)

      expect(described_class.lookup(:foo)).to eq(other_klass)
    end
  end

  describe Webhooks::ErpAdapters::MappingError do
    it 'carries an indexed errors array exposed via #errors' do
      err = described_class.new(errors: [{ index: 0, raw_payload_key: 'sku', message: 'missing' }])

      expect(err.errors).to eq([{ index: 0, raw_payload_key: 'sku', message: 'missing' }])
      expect(err.message).to eq('ERP payload mapping failed')
    end
  end

  describe Webhooks::ErpAdapters::Base do
    it 'forces concrete adapters to implement #to_bulk_params' do
      expect { described_class.new.to_bulk_params({}) }.to raise_error(NotImplementedError)
    end
  end

  describe Webhooks::ErpAdapters::NoopAdapter do
    it 'pass-throughs the products array from the payload' do
      payload = { 'products' => [{ 'name' => 'A', 'kind' => 'physical' }] }

      expect(described_class.new.to_bulk_params(payload)).to eq(
        products: [{ 'name' => 'A', 'kind' => 'physical' }]
      )
    end

    it 'returns an empty products array when the key is missing' do
      expect(described_class.new.to_bulk_params({})).to eq(products: [])
    end
  end
end
