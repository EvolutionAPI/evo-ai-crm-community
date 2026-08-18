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

  def login_as(user, *granted)
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = user
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
    it "404s a third party on another user's personal macro and leaves it unchanged" do
      login_as(third_party, 'macros.update')

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

      expect(response).to have_http_status(:success)
      expect(Macro.exists?(personal_macro.id)).to be(false)
    end
  end

  describe 'POST /api/v1/macros/:id/execute (execute)' do
    it "404s a third party on another user's personal macro" do
      login_as(third_party, 'macros.execute')

      post "/api/v1/macros/#{personal_macro.id}/execute", params: { conversation_ids: [] }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
