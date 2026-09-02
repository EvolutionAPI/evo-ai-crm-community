# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::EventDataPresenter do
  # The label list is faked so the resolution itself is what is under test.
  def presenter_for(label_list)
    described_class.new(Struct.new(:label_list).new(label_list))
  end

  def count_queries
    count = 0
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      count += 1 unless payload[:name].to_s.in?(%w[SCHEMA TRANSACTION])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  describe '#push_labels_data' do
    let!(:urgent) { Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true) }
    let!(:vip) { Label.create!(title: 'vip', color: '#00ff00', show_on_sidebar: false) }

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

    # ConversationSerializer looks the raw tag up in an index keyed by `label.id.to_s`,
    # so an upper-case id tag renders no chip over REST.
    it 'drops a legacy id written in upper case, as the REST serializer does' do
      result = presenter_for([urgent.id.to_s.upcase]).send(:push_labels_data)

      expect(result).to eq([])
    end

    # The ChatContext merge drops any incoming label without a colour.
    it 'falls back to the column default when the row has a blank colour' do
      urgent.update_column(:color, '')

      result = presenter_for(['urgente']).send(:push_labels_data)

      expect(result).to eq([{ id: urgent.id, title: 'urgente', color: '#1f93ff' }])
    end

    it 'resolves a title whose casing predates the downcase hook on Label' do
      urgent.update_column(:title, 'Urgente')

      result = presenter_for(['urgente']).send(:push_labels_data)

      expect(result).to eq([{ id: urgent.id, title: 'Urgente', color: '#ff0000' }])
    end

    it 'emits the label once when both its title and its id are tagged' do
      result = presenter_for([urgent.id.to_s, 'urgente']).send(:push_labels_data)

      expect(result).to eq([{ id: urgent.id, title: 'urgente', color: '#ff0000' }])
    end

    it 'drops tags that resolve to no label, like the REST serializer does' do
      result = presenter_for(%w[urgente sumiu]).send(:push_labels_data)

      expect(result).to eq([{ id: urgent.id, title: 'urgente', color: '#ff0000' }])
    end

    it 'returns an empty list without touching the database when there are no tags' do
      expect(count_queries { presenter_for([]).send(:push_labels_data) }).to eq(0)
    end

    it 'resolves the whole list in a single query' do
      expect(count_queries { presenter_for([urgent.id.to_s, 'vip']).send(:push_labels_data) }).to eq(1)
    end
  end

  describe '#push_data' do
    let!(:label) { Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true) }

    def conversation_double
      now = Time.zone.parse('2026-08-14 10:00:00')

      double('Conversation',
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
    end

    it 'keeps labels as titles and adds labels_data alongside it' do
      result = described_class.new(conversation_double).push_data

      expect(result[:labels]).to eq(['urgente'])
      expect(result[:labels_data]).to eq([{ id: label.id, title: 'urgente', color: '#ff0000' }])
    end

    it 'omits labels_data entirely when built for the webhook egress' do
      result = described_class.new(conversation_double).push_data(include_labels_data: false)

      expect(result).not_to have_key(:labels_data)
      expect(result[:labels]).to all(be_a(String))
    end

    it 'costs no label query when built for the webhook egress' do
      presenter = described_class.new(conversation_double)

      expect(count_queries { presenter.push_data(include_labels_data: false) }).to eq(0)
    end
  end
end
