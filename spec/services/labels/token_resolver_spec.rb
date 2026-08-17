# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Labels::TokenResolver do
  let!(:urgent) { Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true) }
  let(:ghost_id) { SecureRandom.uuid }

  describe '.titles_for' do
    it 'translates an id into the title behind it' do
      expect(described_class.titles_for([urgent.id.to_s])).to eq(['urgente'])
    end

    it 'leaves a title untouched' do
      expect(described_class.titles_for(%w[urgente vip])).to eq(%w[urgente vip])
    end

    # The whole point of the consolidation: dropping the token turns "tag with
    # this" into "tag with nothing" while the caller still reads success.
    it 'preserves an id that resolves to no label' do
      expect(described_class.titles_for([ghost_id])).to eq([ghost_id])
    end

    it 'keeps a resolvable token alongside an unresolvable one' do
      expect(described_class.titles_for([urgent.id.to_s, ghost_id])).to eq(['urgente', ghost_id])
    end

    it 'mixes titles and ids in the order they arrived' do
      expect(described_class.titles_for(['vip', urgent.id.to_s])).to eq(%w[vip urgente])
    end

    it 'deduplicates a label reached by both its id and its title' do
      expect(described_class.titles_for(['urgente', urgent.id.to_s])).to eq(['urgente'])
    end

    it 'accepts a bare scalar' do
      expect(described_class.titles_for(urgent.id.to_s)).to eq(['urgente'])
    end

    it 'drops blank tokens' do
      expect(described_class.titles_for(['urgente', '', nil])).to eq(['urgente'])
    end

    it 'answers an empty list for empty input' do
      expect(described_class.titles_for([])).to eq([])
      expect(described_class.titles_for(nil)).to eq([])
    end

    # An id-free list has nothing to translate, so the labels table is not worth
    # a round trip — this runs on every automation firing.
    it 'does not query the labels table when no id is present' do
      expect(Label).not_to receive(:where)

      described_class.titles_for(%w[urgente vip])
    end
  end
end
