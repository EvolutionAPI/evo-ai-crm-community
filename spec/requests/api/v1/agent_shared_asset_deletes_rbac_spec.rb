# frozen_string_literal: true

require 'rails_helper'

# Negative proof for CRM-190 — the hardened default `agent` role must be BLOCKED
# on deleting shared, account-wide assets (labels/macros/canned_responses/
# message_templates) while keeping read/create/update and macros.execute. evo-auth
# stops seeding the *.delete keys; these are the CRM-side gates that enforce it.
#
# Every deny example grants exactly AGENT_ASSET_KEYS — the set the agent keeps
# after CRM-190 — and every deny is paired with the ALLOW that adds only the
# `*.delete` key, so the pair proves the gate maps to THAT key: a gate re-pointed
# at another key fails the deny, and a gate dropped altogether fails the deny too.
# Each pair also asserts the record survived / is gone, so a 403 that still wrote
# (or an allow that silently no-oped) cannot pass.
#
# The one deliberate exception is `macros.delete`: a macro an agent creates is
# forced to `personal` (Macro#set_visibility), so it is not a shared asset and its
# owner may delete it without the key — see the carve-out examples at the bottom.
RSpec.describe 'Agent shared-asset deletes RBAC (CRM-190)', type: :request do
  # What the default `agent` keeps after CRM-190 and CRM-70: labels and canned
  # responses stay fully agent-managed, macros and message templates keep only what
  # the chat needs (their create/update moved to `<resource>.manage`), and NONE of
  # the *.delete keys is granted.
  AGENT_ASSET_KEYS = %w[
    labels.read labels.create labels.update
    canned_responses.read canned_responses.create canned_responses.update
    message_templates.read
    macros.read macros.execute
  ].freeze

  let(:user) { User.create!(name: 'Agent Probe', email: "agent-#{SecureRandom.hex(4)}@example.com") }
  let(:other_user) { User.create!(name: 'Other Agent', email: "other-#{SecureRandom.hex(4)}@example.com") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    grant(AGENT_ASSET_KEYS)
  end

  after { Current.reset }

  # Model the real hardened agent: it holds exactly `keys` and nothing else.
  def grant(keys)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      keys.include?(permission)
    end
  end

  def create_label
    Label.create!(title: "label-#{SecureRandom.hex(4)}")
  end

  def create_macro(owner: nil, visibility: :global)
    Macro.create!(name: "Macro #{SecureRandom.hex(4)}", visibility: visibility,
                  created_by_id: owner&.id, actions: [])
  end

  def create_canned_response
    CannedResponse.create!(content: 'hello', short_code: "cr-#{SecureRandom.hex(4)}")
  end

  def create_message_template
    MessageTemplate.create!(name: "tpl-#{SecureRandom.hex(4)}", content: 'hello')
  end

  # --- Destroy of a shared asset: denied without the key, allowed with it ---

  # `unknown_id_status` — the status a non-holder gets on an id that isn't there.
  # For labels/canned_responses/message_templates the destroy gate fires BEFORE the
  # fetch, so an unknown id is a uniform 403 (the classic "don't leak existence" via
  # the gate). Macros diverge as of CRM-195: MacrosController#fetch_macro scopes by
  # Macro.with_visibility and renders 404 in the before_action, ahead of
  # check_destroy_permission!. An id outside the caller's scope — unknown OR another
  # user's personal macro — 404s before the gate. That is deliberate: hiding "user X
  # has a personal macro at this UUID" outranks a uniform 403. The cost is that a GLOBAL
  # id stays distinguishable from an unknown one (403 vs 404) by a caller holding NO
  # macro key at all — destroy has no require_permissions entry to stop it before the
  # fetch. Accepted: a global macro is an account-wide shared asset, and every list
  # already hands it to any macros.read holder. macros_visibility_scope_rbac_spec pins
  # that split so it stays a decision instead of drifting back by accident.
  {
    'labels' => { key: 'labels.delete', model: Label, factory: :create_label, unknown_id_status: :forbidden },
    'macros' => { key: 'macros.delete', model: Macro, factory: :create_macro, unknown_id_status: :not_found },
    'canned_responses' => { key: 'canned_responses.delete', model: CannedResponse, factory: :create_canned_response, unknown_id_status: :forbidden },
    'message_templates' => { key: 'message_templates.delete', model: MessageTemplate,
                             factory: :create_message_template, unknown_id_status: :forbidden }
  }.each do |resource, spec|
    describe "DELETE /api/v1/#{resource}/:id (#{spec[:key]})" do
      it 'denies the hardened agent and leaves the record in place' do
        record = send(spec[:factory])

        delete "/api/v1/#{resource}/#{record.id}", as: :json

        expect(response).to have_http_status(:forbidden)
        expect(spec[:model].exists?(record.id)).to be(true)
      end

      it 'does not leak whether the record exists (gate-before-fetch 403, except macros which scope-404 — see comment above)' do
        delete "/api/v1/#{resource}/#{SecureRandom.uuid}", as: :json

        expect(response).to have_http_status(spec[:unknown_id_status])
      end

      it "allows it once #{spec[:key]} is granted (proves the gate maps to that key)" do
        record = send(spec[:factory])
        grant(AGENT_ASSET_KEYS + [spec[:key]])

        delete "/api/v1/#{resource}/#{record.id}", as: :json

        expect(response).to have_http_status(:ok)
        expect(spec[:model].exists?(record.id)).to be(false)
      end
    end
  end

  # --- Reads the agent keeps: allowed with the key, denied without it ---

  %w[macros canned_responses message_templates labels].each do |resource|
    describe "GET /api/v1/#{resource} (#{resource}.read)" do
      it 'lists for the hardened agent' do
        get "/api/v1/#{resource}", as: :json

        expect(response).to have_http_status(:ok)
      end

      it "denies without #{resource}.read (proves the list is actually gated)" do
        grant(AGENT_ASSET_KEYS - ["#{resource}.read"])

        get "/api/v1/#{resource}", as: :json

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  # --- macros.execute stays attendance ---

  describe 'POST /api/v1/macros/:id/execute (macros.execute)' do
    it 'passes the gate for the hardened agent (a missing macro then 404s)' do
      post "/api/v1/macros/#{SecureRandom.uuid}/execute", params: { conversation_ids: [] }, as: :json

      expect(response).to have_http_status(:not_found)
      # The code, not just the status: this endpoint has two different 404s.
      expect(response.parsed_body.dig('error', 'code')).to eq('MACRO_NOT_FOUND')
    end

    it 'denies without macros.execute' do
      grant(AGENT_ASSET_KEYS - ['macros.execute'])

      post "/api/v1/macros/#{SecureRandom.uuid}/execute", params: { conversation_ids: [] }, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  # --- Carve-out: a personal macro is not a shared asset ---

  describe 'DELETE /api/v1/macros/:id — personal macro carve-out' do
    it 'lets the owner delete their own personal macro without macros.delete' do
      macro = create_macro(owner: user, visibility: :personal)

      delete "/api/v1/macros/#{macro.id}", as: :json

      expect(response).to have_http_status(:ok)
      expect(Macro.exists?(macro.id)).to be(false)
    end

    it "does not extend the carve-out to another agent's personal macro" do
      macro = create_macro(owner: other_user, visibility: :personal)

      delete "/api/v1/macros/#{macro.id}", as: :json

      # CRM-195: another user's personal macro is outside Macro.with_visibility for
      # this caller, so fetch_macro 404s in the before_action — ahead of the carve-out
      # check. It is 404 (not 403) on purpose: the response must not reveal that a
      # personal macro exists at this id. Either way the carve-out never fires for
      # someone else's macro and the record survives.
      expect(response).to have_http_status(:not_found)
      expect(Macro.exists?(macro.id)).to be(true)
    end

    it 'does not extend the carve-out to a global macro the agent created' do
      macro = create_macro(owner: user, visibility: :global)

      delete "/api/v1/macros/#{macro.id}", as: :json

      expect(response).to have_http_status(:forbidden)
      expect(Macro.exists?(macro.id)).to be(true)
    end
  end
end
