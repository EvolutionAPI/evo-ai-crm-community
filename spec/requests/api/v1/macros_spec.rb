# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe 'Api::V1::MacrosController', type: :request do
  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'Test User', email: "macros-test-#{SecureRandom.hex(4)}@example.com") }

  around do |example|
    original_base_url = ENV['EVO_AUTH_SERVICE_URL']
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
  end

  before do
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: {
          success: true,
          data: {
            user: { id: user.id, email: user.email }
          }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    permission_check_url = "#{base_url}/api/v1/users/#{user.id}/check_permission"
    stub_request(:post, permission_check_url)
      .to_return(
        status: 200,
        body: {
          success: true,
          data: { has_permission: true }
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    Current.user = user
  end

  describe 'POST /api/v1/macros' do
    it 'creates a macro successfully' do
      post '/api/v1/macros',
           params: {
             name: 'Test Macro',
             actions: [{ action_name: 'assign_team', action_params: ['1'] }],
             visibility: 'global'
           },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      parsed = JSON.parse(response.body)
      expect(parsed['data']['name']).to eq('Test Macro')
    end

    # Pins the round-trip the form relies on — an action param comes back from
    # create and from show byte for byte, for any first hex digit.
    #
    # It does NOT guard the bug itself. The `parseInt(uuid) || uuid` coercion
    # lived in the form and never in Ruby, so nothing here can fail if it comes
    # back; MacroActionRow.spec.tsx is what catches that.
    %w[0 1 2 3 4 5 6 7 8 9 a b c d e f].each do |first_digit|
      it "persists an action param uuid starting with #{first_digit} verbatim" do
        team_id = "#{first_digit}#{SecureRandom.uuid[1..]}"

        post '/api/v1/macros',
             params: {
               name: "Macro #{first_digit}",
               actions: [{ action_name: 'assign_team', action_params: [team_id] }],
               visibility: 'global'
             },
             headers: headers,
             as: :json

        expect(response).to have_http_status(:success)
        created = response.parsed_body['data']
        expect(created['actions'].first['action_params']).to eq([team_id])

        # Reopening the macro must show the very same selection back.
        get "/api/v1/macros/#{created['id']}", headers: headers, as: :json

        expect(response).to have_http_status(:success)
        reopened = response.parsed_body['data']
        expect(reopened['actions'].first['action_params']).to eq([team_id])
      end
    end
  end

  # CRM-152. Two bugs met on this endpoint: the job resolved the WHOLE id list as
  # uuid the moment ONE id had a hyphen (dropping every display_id in a mixed list),
  # and the controller answered 200 with an empty `executions` when nothing resolved
  # — which the chat read as "no failures" and painted green.
  describe 'POST /api/v1/macros/:id/execute' do
    # remove_assigned_team is the cheapest action that needs no params and no other
    # record, so these examples fail on id resolution and nothing else.
    let!(:macro) do
      Macro.create!(
        name: 'Exec Macro',
        visibility: :global,
        actions: [{ 'action_name' => 'remove_assigned_team', 'action_params' => [] }]
      )
    end

    let(:channel) { Channel::Api.create! }
    let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(4)}", channel: channel) }
    let(:contact) { Contact.create!(name: 'C', email: "c-#{SecureRandom.hex(4)}@example.com") }

    def conversation!
      contact_inbox = ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8))
      Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
    end

    it 'answers 404 when no conversation id resolves' do
      missing = SecureRandom.uuid

      post "/api/v1/macros/#{macro.id}/execute",
           params: { conversation_ids: [missing] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:not_found)
      body = response.parsed_body
      expect(body['success']).to be(false)
      expect(body['error']['code']).to eq('CONVERSATION_NOT_FOUND')
      expect(body['error']['details']['unresolved_conversation_ids']).to eq([missing])
    end

    it 'resolves a mixed uuid + display_id list without dropping either' do
      by_uuid = conversation!
      by_display_id = conversation!

      post "/api/v1/macros/#{macro.id}/execute",
           params: { conversation_ids: [by_uuid.id, by_display_id.display_id] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      data = response.parsed_body['data']
      expect(data['executions'].map { |e| e['conversation_id'] })
        .to contain_exactly(by_uuid.id, by_display_id.id)
      expect(data['unresolved_conversation_ids']).to eq([])
    end

    it 'answers 200 with the executions AND the unresolved ids on a partial resolution' do
      existing = conversation!
      missing = SecureRandom.uuid

      post "/api/v1/macros/#{macro.id}/execute",
           params: { conversation_ids: [existing.id, missing] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      data = response.parsed_body['data']
      expect(data['executions'].map { |e| e['conversation_id'] }).to eq([existing.id])
      expect(data['unresolved_conversation_ids']).to eq([missing])
    end

    it 'runs the macro once when the same conversation arrives as uuid AND display_id' do
      conversation = conversation!

      post "/api/v1/macros/#{macro.id}/execute",
           params: { conversation_ids: [conversation.id, conversation.display_id] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['data']['executions'].size).to eq(1)
      # The response alone cannot tell "deduplicated" from "silently dropped the
      # display_id" — the row count can.
      expect(MacroExecution.where(conversation_id: conversation.id).count).to eq(1)
      expect(response.parsed_body['data']['unresolved_conversation_ids']).to eq([])
    end

    # The job used to look at the primary key only. It now goes through
    # ConversationResolver, which also accepts the `uuid` column — pinned here so the
    # widening is deliberate instead of an accident of the refactor.
    it 'resolves a conversation by its uuid column' do
      conversation = conversation!

      post "/api/v1/macros/#{macro.id}/execute",
           params: { conversation_ids: [conversation.uuid] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['data']['executions'].map { |e| e['conversation_id'] })
        .to eq([conversation.id])
    end

    it 'answers 422 when conversation_ids is empty' do
      post "/api/v1/macros/#{macro.id}/execute",
           params: { conversation_ids: [] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'code')).to eq('MISSING_REQUIRED_FIELD')
    end

    # A blank entry is the same silent disappearance this card exists to remove, so it
    # has to come back as unresolved rather than be quietly dropped from both lists.
    # (A literal `nil` never gets this far — Rails' deep_munge strips nils out of
    # params arrays before the action runs, so `""` is the blank that can actually
    # arrive.)
    it 'reports a blank id as unresolved instead of dropping it' do
      existing = conversation!

      post "/api/v1/macros/#{macro.id}/execute",
           params: { conversation_ids: [existing.id, '', '   '] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      data = response.parsed_body['data']
      expect(data['executions'].size).to eq(1)
      expect(data['unresolved_conversation_ids']).to eq(['', '   '])
    end

    # Both id lists are strings, so a caller can diff what it sent against what did
    # not resolve without tripping over 123 != "123".
    it 'echoes conversation_ids with the same type as unresolved_conversation_ids' do
      existing = conversation!
      missing = SecureRandom.uuid

      post "/api/v1/macros/#{macro.id}/execute",
           params: { conversation_ids: [existing.display_id, missing] },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:success)
      data = response.parsed_body['data']
      expect(data['conversation_ids']).to eq([existing.display_id.to_s, missing])
      expect(data['conversation_ids'] - data['unresolved_conversation_ids'])
        .to eq([existing.display_id.to_s])
    end
  end
end
