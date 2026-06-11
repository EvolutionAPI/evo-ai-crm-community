# frozen_string_literal: true

# EVO-1551 round 6 — regression net.
#
# This is the safety spec that closes the whack-a-mole of `content_attributes`
# PII leaks across REST / WebSocket / outbound webhook paths. It does TWO jobs:
#
# 1. Builds a message whose `content_attributes` contains every known
#    PII-bearing key (`submitted_email`, `submitted_values`, `email`) and walks
#    every registered egress shape (model broadcast helpers, JSON serializers).
#    Asserts no raw PII token appears in any of them when the masking flag is
#    on.
#
# 2. Walks the files scoped by the `NoRawContentAttributesInEgress` Rubocop
#    cop and asserts none of them contains a raw `.content_attributes` send.
#    This is defence-in-depth — if the cop is disabled or someone adds a new
#    egress file outside the cop's `Include`, this spec still fails CI.
#
# Add a new egress shape? Register it in EGRESS_PATHS below AND in the cop
# config. The meta-test will tell you if you forget.
require 'rails_helper'

module Evo1551
  module PiiEgressFixtures
    PII_TOKENS = %w[
      leak@example.com
      5511999998888
      99998888
    ].freeze

    CONTENT_ATTRIBUTES_WITH_PII = {
      'submitted_email' => 'leak@example.com',
      'submitted_values' => [{ 'name' => 'phone', 'value' => '+5511999998888' }],
      'email' => { 'from' => ['leak@example.com'], 'subject' => 'Subject 99998888' },
      'in_reply_to' => 42,
      'csat_survey_response' => { 'rating' => 5 }
    }.freeze

    # Each entry: human label => lambda(message) => serialized String.
    EGRESS_PATHS = {
      'Message#push_event_data (WebSocket broadcast)' =>
        ->(m) { m.push_event_data.to_json },
      'Message#webhook_data (outbound webhook payload)' =>
        ->(m) { m.webhook_data.to_json },
      'MessageSerializer (REST)' =>
        ->(m) { MessageSerializer.new(m).to_json },
      'ConversationSerializer (last_non_activity_message preview)' =>
        ->(m) { ConversationSerializer.new(m.conversation).to_json }
    }.freeze

    # Paths mirror the `NoRawContentAttributesInEgress` Include glob in
    # .rubocop.yml. Keep in sync.
    EGRESS_GLOBS = %w[
      app/serializers/**/*.rb
      app/views/**/*.jbuilder
      app/models/message.rb
      app/listeners/webhook_listener.rb
      app/listeners/action_cable_listener.rb
    ].freeze

    # `.content_attributes` NOT followed by `_for_egress`, NOT an assignment
    # LHS, and NOT in a comment. Implicit-self reads inside Message itself
    # are intentionally NOT caught — the cop's AST matcher handles the
    # nuance at lint time; this regex is the coarse-net guard.
    RAW_PATTERN = /(?<![A-Za-z_])\.content_attributes(?![A-Za-z_])(?!\s*=(?!=))/
  end
end

RSpec.describe 'PII egress invariant — EVO-1551 round 6 safety net' do # rubocop:disable RSpec/DescribeClass
  let(:account_settings) { { 'settings' => { 'mask_contact_pii' => true } } }

  # Mirror the AR.create! pattern from spec/jobs/action_cable_broadcast_job_spec.rb.
  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: "https://w-#{SecureRandom.hex(4)}.example.com") }
  let(:inbox) { Inbox.create!(name: 'Egress Inbox', channel: channel) }
  let(:contact_inbox) do
    ContactInbox.create!(inbox: inbox, contact: contact, source_id: "src-#{SecureRandom.hex(4)}")
  end
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:message) do
    Message.create!(
      conversation: conversation,
      inbox: inbox,
      sender: contact,
      message_type: :incoming,
      content: 'irrelevant',
      content_attributes: Evo1551::PiiEgressFixtures::CONTENT_ATTRIBUTES_WITH_PII
    )
  end

  before do
    Current.account = account_settings
    Current.user = nil # agent-ish: no admin shortcut
    allow(RuntimeConfig).to receive(:account).and_return(account_settings)
  end

  after do
    Current.account = nil
    Current.user = nil
  end

  Evo1551::PiiEgressFixtures::EGRESS_PATHS.each do |label, path|
    it "does not leak PII via #{label}" do
      output = path.call(message)

      Evo1551::PiiEgressFixtures::PII_TOKENS.each do |tok|
        expect(output).not_to include(tok),
                              "PII token #{tok.inspect} leaked via #{label}.\n" \
                              "Payload: #{output}"
      end
    end
  end

  it 'preserves non-PII keys (in_reply_to) on the broadcast frame' do
    frame = message.push_event_data
    expect(frame[:content_attributes]).to(include('in_reply_to' => 42).or(include(in_reply_to: 42)))
  end

  describe 'static code invariant — cop-scoped files contain no raw .content_attributes' do
    Evo1551::PiiEgressFixtures::EGRESS_GLOBS.each do |glob|
      it "has no raw `.content_attributes` reads in #{glob}" do
        pattern = Evo1551::PiiEgressFixtures::RAW_PATTERN
        offenders = Dir[Rails.root.join(glob)].flat_map do |file|
          File.foreach(file).with_index(1).filter_map do |line, lineno|
            next if line.lstrip.start_with?('#')
            next unless line.match?(pattern)

            "#{file}:#{lineno}: #{line.strip}"
          end
        end

        expect(offenders).to(be_empty,
                             'Raw `.content_attributes` reads found in egress paths — ' \
                             "route them through `content_attributes_for_egress(audience:)`:\n" +
                             offenders.join("\n"))
      end
    end
  end
end
