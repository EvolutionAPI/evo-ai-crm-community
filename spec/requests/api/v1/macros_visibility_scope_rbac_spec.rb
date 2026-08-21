# frozen_string_literal: true

require 'rails_helper'

# CRM-195 — the macro member actions (show/update/destroy/execute) must scope the
# direct-by-id lookup by the SAME visibility rule as the list (Macro.with_visibility
# = global + the caller's own personal), instead of a raw find_by. Otherwise a third
# party reaches another user's PERSONAL macro by UUID even though every list hides
# it. A third party gets a uniform 404 (never 200/403), the owner keeps access, and
# the CRM-190 carve-out (owner deletes own personal without macros.delete) holds.
RSpec.describe 'Macro visibility scope on member actions (CRM-195)', type: :request do
  let(:owner) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:third_party) { User.create!(name: 'Third', email: "third-#{SecureRandom.hex(4)}@example.com") }

  let(:personal_macro) do
    Macro.create!(name: 'Owner personal', visibility: :personal, created_by_id: owner.id, actions: [])
  end
  let(:global_macro) do
    Macro.create!(name: 'Team global', visibility: :global, created_by_id: owner.id, actions: [])
  end

  def login_as(user, *granted, role: nil)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = user
      # administrator? derives from Current.evo_role_key; set it inside the stub so it
      # survives Rails' per-request Current reset (same reason Current.user is set here).
      Current.evo_role_key = role if role
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_svc, _uid, permission|
      granted.include?(permission)
    end
  end

  after { Current.reset }

  describe 'GET /api/v1/macros/:id (show)' do
    it 'lets the owner read their own personal macro (200)' do
      login_as(owner, 'macros.read')

      get "/api/v1/macros/#{personal_macro.id}", as: :json

      expect(response).to have_http_status(:ok)
    end

    it "404s a third party on another user's personal macro — no 200 leak by UUID" do
      login_as(third_party, 'macros.read')

      get "/api/v1/macros/#{personal_macro.id}", as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'serves a GLOBAL macro to anyone holding macros.read (200)' do
      login_as(third_party, 'macros.read')

      get "/api/v1/macros/#{global_macro.id}", as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'PATCH /api/v1/macros/:id (update)' do
    # CRM-70 moved update to macros.manage, so the key this used to pass no longer
    # authorizes anything: what lets the owner through is the carve-out, same as
    # delete below. Asserting it with NO key is what actually pins that.
    it 'preserves the CRM-70 carve-out: the owner updates their own personal macro WITHOUT macros.manage' do
      login_as(owner) # no keys

      patch "/api/v1/macros/#{personal_macro.id}", params: { name: 'renamed' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(personal_macro.reload.name).to eq('renamed')
    end

    it "404s a third party on another user's personal macro and leaves it unchanged" do
      login_as(third_party, 'macros.manage')

      patch "/api/v1/macros/#{personal_macro.id}", params: { name: 'hijacked' }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(personal_macro.reload.name).to eq('Owner personal')
    end
  end

  describe 'DELETE /api/v1/macros/:id (destroy)' do
    it '404s a third party even WITH macros.delete, and keeps the macro (404 before the gate)' do
      login_as(third_party, 'macros.delete')

      delete "/api/v1/macros/#{personal_macro.id}", as: :json

      expect(response).to have_http_status(:not_found)
      expect(Macro.exists?(personal_macro.id)).to be(true)
    end

    it 'preserves the CRM-190 carve-out: the owner deletes their own personal macro WITHOUT macros.delete' do
      login_as(owner) # no keys

      delete "/api/v1/macros/#{personal_macro.id}", as: :json

      expect(response).to have_http_status(:ok)
      expect(Macro.exists?(personal_macro.id)).to be(false)
    end
  end

  # Card item 2 — locks the product decision that an ADMIN is scoped like everyone
  # else on the member actions. Macro.with_visibility (app/models/macro.rb) has no
  # admin branch today: even a third-party admin does not see another user's personal
  # macro, so they 404. The role: 'administrator' stub is INERT on today's path (the
  # 404 comes purely from with_visibility ignoring this caller — nothing here reads
  # Current.evo_role_key yet). It exists to ARM the lock: if someone later adds an
  # admin-sees-all branch to with_visibility (which WOULD consult administrator? →
  # Current.evo_role_key), the member actions silently reopen — and only because the
  # role is stubbed does this example then turn red first and force a re-gate.
  # Verified with a red-check: injecting that branch flips both examples 404→200.
  describe 'a third-party ADMIN is scoped too (no admin bypass on member actions)' do
    it "404s a third-party admin on another user's personal macro (show)" do
      login_as(third_party, 'macros.read', role: 'administrator')

      get "/api/v1/macros/#{personal_macro.id}", as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "404s a third-party admin on another user's personal macro even WITH macros.delete (destroy)" do
      login_as(third_party, 'macros.delete', role: 'administrator')

      delete "/api/v1/macros/#{personal_macro.id}", as: :json

      expect(response).to have_http_status(:not_found)
      expect(Macro.exists?(personal_macro.id)).to be(true)
    end
  end

  describe 'POST /api/v1/macros/:id/execute (execute)' do
    # Inert payload: what this pins is the scoped fetch, not the execution.
    it 'lets the owner reach execute on their own personal macro' do
      login_as(owner, 'macros.execute')

      post "/api/v1/macros/#{personal_macro.id}/execute", params: { conversation_ids: [] }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.dig('error', 'code')).to eq('MISSING_REQUIRED_FIELD')
    end

    # The code, not just the status: this endpoint has two different 404s.
    it "404s a third party on another user's personal macro" do
      login_as(third_party, 'macros.execute')

      post "/api/v1/macros/#{personal_macro.id}/execute", params: { conversation_ids: [] }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig('error', 'code')).to eq('MACRO_NOT_FOUND')
    end
  end

  # The scoped fetch reads `current_user`, and a service token authenticates with none
  # (ServiceTokenAuthConcern). Before the Macro.with_visibility nil guard this raised
  # NoMethodError on `nil.id` and every member action answered 500 — invisible to every
  # lane, because nothing else exercises the service-token path on macros.
  describe 'service-token caller (no user in Current)' do
    around do |example|
      previous = ENV.fetch('EVOAI_CRM_API_TOKEN', nil)
      ENV['EVOAI_CRM_API_TOKEN'] = 'service-token-probe'
      example.run
      ENV['EVOAI_CRM_API_TOKEN'] = previous
    end

    let(:service_headers) { { 'X-Service-Token' => 'service-token-probe' } }

    it 'reads a macro instead of crashing on the nil user' do
      get "/api/v1/macros/#{global_macro.id}", headers: service_headers, as: :json

      expect(response).to have_http_status(:ok)
    end

    it 'is elevated, like the policies: it also reads another user\'s personal macro' do
      get "/api/v1/macros/#{personal_macro.id}", headers: service_headers, as: :json

      expect(response).to have_http_status(:ok)
    end
  end

  # Pins the 403-vs-404 split the 404-first order leaves behind, so it stays a decision.
  # A caller with NO macro key at all still separates an existing GLOBAL id (403, from
  # check_destroy_permission!) from an unknown one (404, from the scoped fetch), because
  # destroy carries no require_permissions entry to stop it before the fetch. Accepted:
  # a global macro is an account-wide shared asset. A personal macro must NOT be
  # separable that way — that is the leak CRM-195 closed.
  describe 'DELETE with no macro permission at all — what the 404-first order still tells' do
    before { login_as(third_party) }

    it 'answers 404 for an unknown id' do
      delete "/api/v1/macros/#{SecureRandom.uuid}", as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 403 for an existing GLOBAL macro (accepted: shared asset)' do
      delete "/api/v1/macros/#{global_macro.id}", as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "answers 404 for another user's PERSONAL macro — indistinguishable from unknown" do
      delete "/api/v1/macros/#{personal_macro.id}", as: :json

      expect(response).to have_http_status(:not_found)
      expect(Macro.exists?(personal_macro.id)).to be(true)
    end
  end
end
