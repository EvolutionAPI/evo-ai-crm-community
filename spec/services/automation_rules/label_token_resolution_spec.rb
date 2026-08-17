# frozen_string_literal: true

require 'rails_helper'

# The write axis: turning the tokens a caller sends (label ids, or titles from
# older configurations) into the titles `acts_as_taggable_on` stores. Two copies
# of that translation exist and they do NOT agree on the one case that matters —
# a token holding an id that no longer resolves to a Label row. The automation
# handler drops it; LabelConcern keeps it as a literal, deliberately, so an
# add-label node cannot answer success having tagged nothing.
#
# Both behaviours are pinned here so that consolidating the read paths cannot
# quietly rewrite either one. Which of the two should win is a product call, not
# a refactor's to make.
RSpec.describe 'Label token resolution on the write axis' do
  let!(:urgent) { Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true) }
  let(:ghost_id) { SecureRandom.uuid }

  # The handler module is private-by-inclusion; an anonymous host exposes the
  # single method under test without dragging in the executor's state.
  let(:automation_host) do
    Class.new do
      include AutomationRules::ConversationActionHandlers
      public :resolve_label_titles
    end.new
  end

  let(:controller_host) do
    Class.new do
      include LabelConcern
      public :resolve_label_titles
    end.new
  end

  describe 'the automation handler' do
    it 'translates an id into the title behind it' do
      expect(automation_host.resolve_label_titles([urgent.id.to_s])).to eq(['urgente'])
    end

    it 'leaves a title untouched' do
      expect(automation_host.resolve_label_titles(['urgente'])).to eq(['urgente'])
    end

    it 'drops an id that resolves to no label' do
      expect(automation_host.resolve_label_titles([ghost_id])).to eq([])
    end
  end

  describe 'the controller concern' do
    it 'translates an id into the title behind it' do
      expect(controller_host.resolve_label_titles([urgent.id.to_s])).to eq(['urgente'])
    end

    it 'keeps an id that resolves to no label, so the tagging still happens' do
      expect(controller_host.resolve_label_titles([ghost_id])).to eq([ghost_id])
    end
  end

  it 'documents that the two disagree on an unresolvable id' do
    expect(automation_host.resolve_label_titles([ghost_id])).to eq([])
    expect(controller_host.resolve_label_titles([ghost_id])).to eq([ghost_id])
  end
end
