# frozen_string_literal: true

require 'rails_helper'

# Coverage for EVO-1190 — defense-in-depth at the activity-message render
# boundary. The upstream resolvers (LabelConcern, ActionService#add_label,
# StageAutomationService) keep UUIDs out of `tags.name` for their own write
# paths, but BulkActionsJob, ActionService#remove_label and a few direct
# writers can still leak UUIDs into `previous_changes[:label_list]`. This spec
# locks in two layers: the helper resolves UUIDs in isolation, and a bypass
# write through `update!(label_list: [uuid])` still produces an activity
# message with the title (not the UUID).

RSpec.describe LabelActivityMessageHandler do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:label) { Label.create!(title: "hot-lead-#{SecureRandom.hex(2)}") }

  around do |example|
    Current.user = user
    example.run
  ensure
    Current.reset
  end

  def captured_activity_contents
    contents = []
    allow(Conversations::ActivityMessageJob).to receive(:perform_later) do |_record, params|
      contents << params[:content]
    end
    contents
  end

  describe '#create_label_added' do
    it 'renders the label title when a UUID is dispatched (regression of EVO-1001)' do
      contents = captured_activity_contents
      conversation.send(:create_label_added, user.name, [label.id])

      expect(contents).to include(a_string_matching(/#{Regexp.escape(label.title)}/))
      expect(contents).not_to include(a_string_matching(/#{Regexp.escape(label.id)}/))
    end

    it 'passes plain titles through unchanged' do
      contents = captured_activity_contents
      conversation.send(:create_label_added, user.name, ['hot-lead'])

      expect(contents.last).to include('hot-lead')
    end

    it 'resolves a mixed array of UUID and title in a single activity message' do
      other_label = Label.create!(title: "vip-#{SecureRandom.hex(2)}")
      contents = captured_activity_contents

      conversation.send(:create_label_added, user.name, [label.id, other_label.title])

      expect(contents.last).to include(label.title)
      expect(contents.last).to include(other_label.title)
      expect(contents.last).not_to include(label.id)
    end

    it 'falls back to the raw UUID when the label no longer exists (graceful degradation)' do
      orphan_uuid = SecureRandom.uuid
      contents = captured_activity_contents

      conversation.send(:create_label_added, user.name, [orphan_uuid])

      expect(contents.last).to include(orphan_uuid)
    end

    it 'does not enqueue an activity message when the labels array is empty' do
      expect(Conversations::ActivityMessageJob).not_to receive(:perform_later)
      conversation.send(:create_label_added, user.name, [])
    end
  end

  describe '#create_label_removed' do
    it 'renders the label title when a UUID is dispatched' do
      contents = captured_activity_contents
      conversation.send(:create_label_removed, user.name, [label.id])

      expect(contents.last).to include(label.title)
      expect(contents.last).not_to include(label.id)
    end
  end

  describe 'callback chain on a bypass write (update!(label_list: [uuid]))' do
    # Simulates the BulkActionsJob path: a caller writes `label_list` with a
    # raw UUID, skipping LabelConcern's resolver. The activity message must
    # still render the title because of the render-time guard.
    it 'preserves the title in the resulting activity message when adding' do
      conversation
      contents = captured_activity_contents

      conversation.update!(label_list: [label.id])

      label_activity = contents.find { |c| c&.include?('added') }
      expect(label_activity).to be_present
      expect(label_activity).to include(label.title)
      expect(label_activity).not_to include(label.id)
    end

    it 'preserves the title in the resulting activity message when removing' do
      conversation.update!(label_list: [label.id])
      contents = captured_activity_contents

      conversation.update!(label_list: [])

      label_activity = contents.find { |c| c&.include?('removed') }
      expect(label_activity).to be_present
      expect(label_activity).to include(label.title)
      expect(label_activity).not_to include(label.id)
    end
  end
end
