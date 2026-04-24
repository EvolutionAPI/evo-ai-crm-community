# frozen_string_literal: true

require 'rails_helper'

# Unit-level coverage for LabelConcern's UUID→title resolution. Exercises the
# private `resolve_label_titles` directly via an anonymous host class, since
# the bug class (UUID leaking into `tags.name`) was the regression EVO-1001
# fixed at this seam.
RSpec.describe LabelConcern, type: :concern do
  let(:host_class) do
    Class.new do
      include LabelConcern

      # Make the private helper reachable from specs without polluting the
      # public surface of real controllers that include this concern.
      public :resolve_label_titles
    end
  end

  let(:host) { host_class.new }

  describe '#resolve_label_titles' do
    context 'when input is blank' do
      it 'passes nil through untouched' do
        expect(host.resolve_label_titles(nil)).to be_nil
      end

      it 'passes empty array through untouched' do
        expect(host.resolve_label_titles([])).to eq([])
      end
    end

    context 'with non-UUID strings (titles)' do
      it 'leaves human-readable titles untouched' do
        expect(host.resolve_label_titles(['hot-lead', 'vip'])).to eq(['hot-lead', 'vip'])
      end

      it 'does not query the labels table when no UUID is present' do
        expect(Label).not_to receive(:where)
        host.resolve_label_titles(['plain-string'])
      end
    end

    context 'with UUID inputs' do
      let(:hot_lead_id) { '550e8400-e29b-41d4-a716-446655440000' }
      let(:vip_id) { '6ba7b810-9dad-11d1-80b4-00c04fd430c8' }

      before do
        # Stub the UUID→title lookup in isolation. The concern only relies on
        # `Label.where(id: uuids).pluck(:id, :title)`, so we mock that surface
        # rather than touching the database.
        relation = double('Label::Relation')
        allow(Label).to receive(:where).with(id: array_including(hot_lead_id, vip_id))
                                       .and_return(relation)
        allow(relation).to receive(:pluck).with(:id, :title).and_return(
          [[hot_lead_id, 'hot-lead'], [vip_id, 'vip']]
        )
      end

      it 'resolves all UUIDs to their titles' do
        expect(host.resolve_label_titles([hot_lead_id, vip_id])).to match_array(['hot-lead', 'vip'])
      end

      it 'merges resolved titles with existing title-form entries and dedupes' do
        result = host.resolve_label_titles(['hot-lead', vip_id])
        expect(result).to match_array(['hot-lead', 'vip'])
      end
    end

    context 'with unresolvable UUIDs' do
      let(:ghost_id) { '00000000-0000-0000-0000-000000000000' }

      before do
        relation = double('Label::Relation', pluck: [])
        allow(Label).to receive(:where).with(id: [ghost_id]).and_return(relation)
      end

      it 'silently drops UUIDs that no longer correspond to a label' do
        expect(host.resolve_label_titles([ghost_id])).to eq([])
      end

      it 'preserves non-UUID entries even when all UUIDs are unresolvable' do
        expect(host.resolve_label_titles(['vip', ghost_id])).to eq(['vip'])
      end
    end
  end
end
