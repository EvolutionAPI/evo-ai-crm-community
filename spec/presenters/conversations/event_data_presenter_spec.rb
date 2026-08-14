# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::EventDataPresenter do
  describe '#push_labels_data' do
    let!(:urgent) { Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true) }
    let!(:vip) { Label.create!(title: 'vip', color: '#00ff00', show_on_sidebar: false) }

    def presenter_for(label_list)
      described_class.new(Struct.new(:label_list).new(label_list))
    end

    it 'resolves each title into id, title and color' do
      result = presenter_for(%w[urgente vip]).send(:push_labels_data)

      expect(result).to eq(
        [
          { id: urgent.id, title: 'urgente', color: '#ff0000' },
          { id: vip.id, title: 'vip', color: '#00ff00' }
        ]
      )
    end

    it 'resolves legacy entries that still hold the Label id' do
      result = presenter_for([urgent.id.to_s]).send(:push_labels_data)

      expect(result).to eq([{ id: urgent.id, title: 'urgente', color: '#ff0000' }])
    end

    it 'ignores tags with no matching label' do
      result = presenter_for(%w[urgente sumiu]).send(:push_labels_data)

      expect(result).to eq([{ id: urgent.id, title: 'urgente', color: '#ff0000' }])
    end

    it 'returns an empty list without touching the database when there are no tags' do
      queries = count_queries { presenter_for([]).send(:push_labels_data) }

      expect(queries).to eq(0)
    end

    it 'resolves the whole list in a single query' do
      queries = count_queries { presenter_for([urgent.id.to_s, 'vip']).send(:push_labels_data) }

      expect(queries).to eq(1)
    end

    def count_queries(&block)
      count = 0
      subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        count += 1 unless payload[:name].to_s.in?(%w[SCHEMA TRANSACTION])
      end
      block.call
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end

  describe '#push_data' do
    # This hash is also the webhook body delivered to customer integrations
    # (PushDataHelper#webhook_data), so `labels` has to stay a list of titles.
    it 'keeps labels as titles and adds labels_data alongside it' do
      label = Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true)
      now = Time.zone.parse('2026-08-14 10:00:00')

      conversation = double('Conversation',
        additional_attributes: {},
        can_reply?: true,
        inbox: nil,
        contact_inbox: nil,
        id: SecureRandom.uuid,
        display_id: 1,
        inbox_id: SecureRandom.uuid,
        messages: double('Relation', chat: double('Chat', last: nil)),
        label_list: ['urgente'],
        contact: double('Contact', push_event_data: {}, group?: false),
        assignee: nil,
        team: nil,
        status: 'open',
        custom_attributes: {},
        snoozed_until: nil,
        unread_incoming_messages_count: 0,
        first_reply_created_at: nil,
        priority: nil,
        waiting_since: now,
        agent_last_seen_at: now,
        contact_last_seen_at: now,
        last_activity_at: now,
        created_at: now,
        updated_at: now)

      result = described_class.new(conversation).push_data

      expect(result[:labels]).to eq(['urgente'])
      expect(result[:labels_data]).to eq([{ id: label.id, title: 'urgente', color: '#ff0000' }])
    end
  end
end
