# frozen_string_literal: true

require 'rails_helper'

# A conversation stores its labels as tags — plain strings. Turning a tag back
# into a Label row (id + title + colour) is what every read path needs, and each
# one writes that resolution itself today. The copies have already drifted apart
# once in a way only the screen could see, so these examples pin the semantics
# instead of leaving it to convention:
#
#   * title matches case-insensitively
#   * id matches exactly, because Postgres renders uuid lower-case
#   * a tag matching no label is dropped
#   * a label tagged twice (once by title, once by id) is one chip, not two
#
# Every example asserts the REST payload and the realtime payload land on the
# same chips for the same tags. That agreement is the contract; which path
# computes it is an implementation detail that may be consolidated freely.
RSpec.describe 'Label chip resolution' do
  let!(:urgent) { Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true) }
  let!(:vip) { Label.create!(title: 'vip', color: '#00ff00', show_on_sidebar: false) }

  # The real REST pair: the controller builds the indexes and the serializer
  # consumes them. Building them through the controller (rather than handing the
  # serializer a hash) is the point — that builder is one of the copies.
  def rest_chips(tags)
    indexes = Api::V1::ConversationsController.new.send(:label_indexes)

    ConversationSerializer.serialize(
      conversation_double(tags),
      include_labels: true,
      include_contact: false,
      include_inbox: false,
      labels_by_title: indexes[:by_title],
      labels_by_id: indexes[:by_id]
    )['labels'].map { |chip| chip[:title] }
  end

  def realtime_chips(tags)
    Conversations::EventDataPresenter
      .new(Struct.new(:label_list).new(tags))
      .send(:push_labels_data)
      .map { |chip| chip[:title] }
  end

  def expect_same_chips(tags, chips)
    expect(rest_chips(tags)).to eq(chips)
    expect(realtime_chips(tags)).to eq(chips)
  end

  def conversation_double(tags)
    now = Time.zone.parse('2026-08-17 12:00:00')
    conversation = double(
      'Conversation',
      as_json: { 'id' => 1, 'inbox_id' => 1, 'status' => 'open', 'assignee_id' => nil,
                 'team_id' => nil, 'campaign_id' => nil, 'display_id' => 1,
                 'additional_attributes' => {}, 'priority' => nil },
      created_at: now, updated_at: now, agent_last_seen_at: nil, contact_last_seen_at: nil,
      waiting_since: nil, first_reply_created_at: nil, snoozed_until: nil, last_activity_at: now,
      custom_attributes: {}, unread_incoming_messages_count: 0,
      contact: nil, inbox: nil, assignee: nil, team: nil,
      cached_label_list_array: tags, messages: double('Relation', last: nil)
    )
    allow(conversation).to receive(:association).and_return(double(loaded?: false))
    conversation
  end

  it 'resolves a tag holding the exact title' do
    expect_same_chips(['urgente'], ['urgente'])
  end

  # Label downcases its title on write, but rows tagged before that hook still
  # carry the old casing.
  it 'resolves a tag whose casing differs from the stored title' do
    expect_same_chips(['URGENTE'], ['urgente'])
  end

  # Pre-normalisation data: the tag holds the Label primary key instead of the title.
  it 'resolves a tag holding the label id' do
    expect_same_chips([urgent.id.to_s], ['urgente'])
  end

  # Deliberately case-sensitive. Postgres renders uuid lower-case, so an
  # upper-case id is not a label id — treating it as one would invent a chip
  # the REST payload does not have.
  it 'drops a tag holding the label id in upper case' do
    expect_same_chips([urgent.id.to_s.upcase], [])
  end

  it 'drops a tag that matches no label' do
    expect_same_chips(%w[sumiu], [])
  end

  it 'keeps the labels that do match when a tag alongside them matches none' do
    expect_same_chips(%w[urgente sumiu vip], %w[urgente vip])
  end

  # The same label reached twice is still one chip: the screen cannot render
  # the same badge twice, and the two paths must not disagree about it.
  it 'emits a single chip when both the title and the id of a label are tagged' do
    expect_same_chips(['urgente', urgent.id.to_s], ['urgente'])
  end

  it 'emits no chips for a conversation with no tags' do
    expect_same_chips([], [])
  end

  # Once the indexes are built every label is already in memory, so turning tags
  # into chips must not go back to the database — the realtime path does not, and
  # this is a list endpoint: a query per chip is paid once per conversation on
  # screen.
  it 'builds the chips without a further query per chip' do
    indexes = Api::V1::ConversationsController.new.send(:label_indexes)
    conversation = conversation_double(%w[urgente vip])

    queries = count_queries do
      ConversationSerializer.serialize(
        conversation,
        include_labels: true,
        include_contact: false,
        include_inbox: false,
        labels_by_title: indexes[:by_title],
        labels_by_id: indexes[:by_id]
      )
    end

    expect(queries).to eq(0)
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
end
