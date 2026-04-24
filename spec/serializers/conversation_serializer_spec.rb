# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ConversationSerializer do
  include ActiveSupport::Testing::TimeHelpers

  describe '.serialize' do
    it 'includes timestamp field matching last_activity_at' do
      activity_time = Time.zone.parse('2026-02-12 10:00:00')

      conversation = double('Conversation',
        as_json: { 'id' => 1, 'inbox_id' => 1, 'status' => 'open',
                   'assignee_id' => nil, 'team_id' => nil, 'campaign_id' => nil,
                   'display_id' => 1, 'additional_attributes' => {}, 'priority' => nil },
        created_at: activity_time,
        updated_at: activity_time,
        agent_last_seen_at: nil,
        contact_last_seen_at: nil,
        waiting_since: nil,
        first_reply_created_at: nil,
        snoozed_until: nil,
        last_activity_at: activity_time,
        custom_attributes: {},
        unread_incoming_messages: double('Relation', count: 0),
        contact: nil,
        inbox: nil,
        assignee: nil,
        team: nil,
        cached_label_list_array: [],
        messages: double('Relation', last: nil))

      allow(conversation).to receive(:association).and_return(double(loaded?: false))

      result = described_class.serialize(conversation, include_contact: false, include_inbox: false)

      expect(result['timestamp']).to eq(activity_time.to_i)
      expect(result['timestamp']).to eq(result['last_activity_at'])
    end

    it 'returns nil timestamp when last_activity_at is nil' do
      now = Time.zone.parse('2026-02-12 11:00:00')

      conversation = double('Conversation',
        as_json: { 'id' => 2, 'inbox_id' => 1, 'status' => 'open',
                   'assignee_id' => nil, 'team_id' => nil, 'campaign_id' => nil,
                   'display_id' => 2, 'additional_attributes' => {}, 'priority' => nil },
        created_at: now,
        updated_at: now,
        agent_last_seen_at: nil,
        contact_last_seen_at: nil,
        waiting_since: nil,
        first_reply_created_at: nil,
        snoozed_until: nil,
        last_activity_at: nil,
        custom_attributes: {},
        unread_incoming_messages: double('Relation', count: 0),
        contact: nil,
        inbox: nil,
        assignee: nil,
        team: nil,
        cached_label_list_array: [],
        messages: double('Relation', last: nil))

      allow(conversation).to receive(:association).and_return(double(loaded?: false))

      result = described_class.serialize(conversation, include_contact: false, include_inbox: false)

      expect(result['timestamp']).to be_nil
      expect(result['last_activity_at']).to be_nil
    end
  end

  describe '.serialize with include_labels (EVO-1001)' do
    let(:now) { Time.zone.parse('2026-04-24 12:00:00') }
    let(:label_uuid) { '550e8400-e29b-41d4-a716-446655440000' }
    let(:label_record) do
      double('Label',
             id: label_uuid,
             title: 'hot-lead',
             description: nil,
             color: '#ff0000',
             show_on_sidebar: true,
             created_at: now,
             updated_at: now)
    end

    def build_conversation(cached_label_list_array)
      conversation = double('Conversation',
                            as_json: { 'id' => 1, 'inbox_id' => 1, 'status' => 'open',
                                       'assignee_id' => nil, 'team_id' => nil, 'campaign_id' => nil,
                                       'display_id' => 1, 'additional_attributes' => {}, 'priority' => nil },
                            created_at: now,
                            updated_at: now,
                            agent_last_seen_at: nil,
                            contact_last_seen_at: nil,
                            waiting_since: nil,
                            first_reply_created_at: nil,
                            snoozed_until: nil,
                            last_activity_at: now,
                            custom_attributes: {},
                            unread_incoming_messages: double('Relation', count: 0),
                            contact: nil,
                            inbox: nil,
                            assignee: nil,
                            team: nil,
                            cached_label_list_array: cached_label_list_array,
                            messages: double('Relation', last: nil))
      allow(conversation).to receive(:association).and_return(double(loaded?: false))
      conversation
    end

    it 'resolves a tag stored as title via labels_by_title' do
      conversation = build_conversation(['hot-lead'])
      result = described_class.serialize(
        conversation,
        include_labels: true,
        include_contact: false,
        include_inbox: false,
        labels_by_title: { 'hot-lead' => label_record },
        labels_by_id: {}
      )

      expect(result['labels'].size).to eq(1)
      expect(result['labels'].first[:title]).to eq('hot-lead')
    end

    it 'resolves a tag stored as legacy UUID via labels_by_id fallback' do
      # Pre-fix data: cached_label_list still holds the Label PK as a string.
      # The serializer must fall back to labels_by_id and keep rendering the
      # human-readable label so conversation cards do not silently lose badges.
      conversation = build_conversation([label_uuid])
      result = described_class.serialize(
        conversation,
        include_labels: true,
        include_contact: false,
        include_inbox: false,
        labels_by_title: {},
        labels_by_id: { label_uuid => label_record }
      )

      expect(result['labels'].size).to eq(1)
      expect(result['labels'].first[:title]).to eq('hot-lead')
    end

    it 'prefers title match over id match when both indexes contain the tag' do
      conversation = build_conversation(['hot-lead'])
      other_label = double('Label',
                           id: 'other', title: 'other', description: nil,
                           color: '#000', show_on_sidebar: true,
                           created_at: now, updated_at: now)

      result = described_class.serialize(
        conversation,
        include_labels: true,
        include_contact: false,
        include_inbox: false,
        labels_by_title: { 'hot-lead' => label_record },
        labels_by_id: { 'hot-lead' => other_label }
      )

      expect(result['labels'].first[:title]).to eq('hot-lead')
    end

    it 'drops tags that resolve in neither index' do
      conversation = build_conversation(['ghost-tag', label_uuid])
      result = described_class.serialize(
        conversation,
        include_labels: true,
        include_contact: false,
        include_inbox: false,
        labels_by_title: {},
        labels_by_id: { label_uuid => label_record }
      )

      expect(result['labels'].size).to eq(1)
      expect(result['labels'].first[:title]).to eq('hot-lead')
    end

    it 'returns empty labels array when include_labels is false' do
      conversation = build_conversation([label_uuid])
      result = described_class.serialize(
        conversation,
        include_labels: false,
        include_contact: false,
        include_inbox: false
      )

      expect(result['labels']).to eq([])
    end
  end
end
