# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProductVariant do
  let(:product) do
    Product.create!(name: 'Base', kind: 'physical', default_price: 10, currency: 'BRL')
  end

  # CRM-289: "" is not NULL, so two no-SKU variants would collide on the partial
  # unique index (index_product_variants_on_sku WHERE sku IS NOT NULL).
  describe 'SKU normalization' do
    it 'persists blank sku as NULL and allows a second no-SKU variant' do
      first = product.variants.create!(name: 'P', sku: '')
      expect(first.reload.sku).to be_nil

      expect { product.variants.create!(name: 'M', sku: '') }
        .to change(described_class, :count).by(1)
    end

    it 'normalizes whitespace-only sku to NULL' do
      variant = product.variants.create!(name: 'G', sku: '   ')
      expect(variant.reload.sku).to be_nil
    end

    it 'normalizes a whitespace-only sku longer than the generic 255 guard' do
      variant = product.variants.create!(name: 'GG', sku: ' ' * 300)
      expect(variant.reload.sku).to be_nil
    end

    it 'still rejects a duplicate real sku' do
      product.variants.create!(name: 'P', sku: 'VAR-1')
      dup = product.variants.build(name: 'M', sku: 'VAR-1')
      expect(dup).not_to be_valid
      expect(dup.errors[:sku]).to be_present
    end
  end
end
