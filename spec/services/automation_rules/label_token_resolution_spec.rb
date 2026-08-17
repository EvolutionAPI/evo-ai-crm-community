# frozen_string_literal: true

require 'rails_helper'

# The write axis: every caller that turns a label token into the title
# `acts_as_taggable_on` stores now goes through Labels::TokenResolver, so they
# answer the same thing for the same input. The case that used to separate them
# is an id that no longer resolves to a Label row — the controller concern kept
# it, the automation handler dropped it, and a rule pointing at a deleted label
# therefore tagged nothing while reporting success.
RSpec.describe 'Label token resolution across the write axis' do
  let!(:urgent) { Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true) }
  let(:ghost_id) { SecureRandom.uuid }

  # Both hosts expose the same private helper; an anonymous class reaches it
  # without dragging in the executor's or the controller's state.
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

  shared_examples 'the shared token semantics' do
    it 'translates an id into the title behind it' do
      expect(resolve.call([urgent.id.to_s])).to eq(['urgente'])
    end

    it 'leaves a title untouched' do
      expect(resolve.call(['urgente'])).to eq(['urgente'])
    end

    it 'preserves an id that resolves to no label' do
      expect(resolve.call([ghost_id])).to eq([ghost_id])
    end

    it 'keeps a resolvable token alongside an unresolvable one' do
      expect(resolve.call(['urgente', ghost_id])).to eq(['urgente', ghost_id])
    end
  end

  describe 'the automation handler' do
    let(:resolve) { ->(tokens) { automation_host.resolve_label_titles(tokens) } }

    it_behaves_like 'the shared token semantics'
  end

  describe 'the controller concern' do
    let(:resolve) { ->(tokens) { controller_host.resolve_label_titles(tokens) } }

    it_behaves_like 'the shared token semantics'

    # Blank is the one place the concern deliberately differs: `nil` has to stay
    # `nil` so `create` can tell "sent nothing" from "sent an empty list".
    it 'passes nil through untouched' do
      expect(controller_host.resolve_label_titles(nil)).to be_nil
    end

    it 'passes an empty array through untouched' do
      expect(controller_host.resolve_label_titles([])).to eq([])
    end
  end

  it 'has the two callers agreeing on an unresolvable id' do
    expect(automation_host.resolve_label_titles([ghost_id]))
      .to eq(controller_host.resolve_label_titles([ghost_id]))
  end

  # The contact branch of add_label/remove_label used to bypass the resolver and
  # query `Label.where(id: tokens)` directly. Postgres casts a non-uuid string
  # to NULL rather than raising, so a rule carrying a title matched no row and
  # the contact came back untagged, with no error anywhere.
  describe 'the contact branch of the automation actions' do
    let(:contact) { Contact.create!(name: 'Tagged', email: "tagged-#{SecureRandom.hex(4)}@example.com") }

    let(:rule) do
      rule = AutomationRule.new(
        name: "rule-#{SecureRandom.hex(4)}", event_name: 'contact_updated',
        active: true, mode: 'simple', conditions: [], actions: []
      )
      rule.save!(validate: false)
      rule
    end

    after { Current.reset }

    def run_action(action_name, params)
      AutomationRules::ContactActionService
        .new(rule, contact, recorder: nil)
        .send(:dispatch_native_action, action_name, params)
    end

    it 'tags a contact from a rule holding the label id' do
      run_action('add_label', [urgent.id.to_s])

      expect(contact.reload.label_list).to include('urgente')
    end

    it 'tags a contact from an older rule holding the label title' do
      run_action('add_label', ['urgente'])

      expect(contact.reload.label_list).to include('urgente')
    end

    it 'untags a contact from an older rule holding the label title' do
      contact.update!(label_list: ['urgente'])

      run_action('remove_label', ['urgente'])

      expect(contact.reload.label_list).not_to include('urgente')
    end
  end
end
