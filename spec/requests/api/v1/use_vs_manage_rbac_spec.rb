# frozen_string_literal: true

require 'rails_helper'

# CRM-70 use-vs-manage split: the attendance role USES macros and message
# templates in the chat (read + macros.execute) but does not MANAGE them —
# create/update demand `<resource>.manage`, held by admin roles only. These
# examples exercise the full request stack with the agent's real key set.
RSpec.describe 'Use-vs-manage RBAC (macros, message templates)', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }
  # The default agent key set after CRM-70 (see the auth seed): usage only.
  let(:agent_keys) { %w[macros.read macros.execute message_templates.read] }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
  end

  after { Current.reset }

  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_service, _user_id, permission|
      granted.include?(permission)
    end
  end

  describe 'macros' do
    let(:macro) do
      Macro.create!(name: "m-#{SecureRandom.hex(4)}", visibility: 'global',
                    created_by: user, updated_by: user,
                    actions: [{ 'action_name' => 'add_label', 'action_params' => ['spec'] }])
    end

    it 'denies create/update to the agent key set (403) but keeps the list open' do
      grant_permissions(*agent_keys)

      post '/api/v1/macros', params: { name: 'Nova', actions: [] }, as: :json
      expect(response).to have_http_status(:forbidden)

      patch "/api/v1/macros/#{macro.id}", params: { name: 'Editada' }, as: :json
      expect(response).to have_http_status(:forbidden)

      get '/api/v1/macros', as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'keeps execute open to the agent key set — running a macro is attendance' do
      grant_permissions(*agent_keys)

      post "/api/v1/macros/#{macro.id}/execute", params: { conversation_ids: [] }, as: :json

      # Inert payload: the gate is what is under test, not the execution.
      expect(response).not_to have_http_status(:forbidden)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'allows create/update for a macros.manage holder' do
      grant_permissions('macros.manage', 'macros.read')

      post '/api/v1/macros',
           params: { name: 'Gerenciada', actions: [{ action_name: 'add_label', action_params: ['x'] }] },
           as: :json
      expect(response).to have_http_status(:success)

      patch "/api/v1/macros/#{macro.id}", params: { name: 'Renomeada' }, as: :json
      expect(response).to have_http_status(:success)
    end

    it 'still demands macros.delete (not manage) for the destroy of a shared macro' do
      grant_permissions('macros.manage')

      delete "/api/v1/macros/#{macro.id}", as: :json

      expect(response).to have_http_status(:forbidden)
    end

    # A personal macro is not a shared asset (Macro#set_visibility forces
    # `personal` for every non-admin), so its owner keeps editing it without
    # macros.manage — the same carve-out destroy has since CRM-190. Otherwise the
    # owner could run and delete its macro but never fix a typo in it.
    context 'personal macro carve-out' do
      let(:personal_macro) do
        Macro.create!(name: "p-#{SecureRandom.hex(4)}", visibility: 'personal',
                      created_by: user, updated_by: user,
                      actions: [{ 'action_name' => 'add_label', 'action_params' => ['spec'] }])
      end

      it 'lets the owner edit its own personal macro with the agent key set' do
        grant_permissions(*agent_keys)

        patch "/api/v1/macros/#{personal_macro.id}", params: { name: 'Corrigida' }, as: :json

        expect(response).to have_http_status(:success)
      end

      # CRM-195 scoped fetch_macro, so another user's personal macro is 404 (not
      # 403) — hiding that the id exists outranks a uniform denial. What matters
      # here is that the carve-out never reaches it.
      it 'does not extend the carve-out to someone else personal macro' do
        other = User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com")
        foreign = Macro.create!(name: "f-#{SecureRandom.hex(4)}", visibility: 'personal',
                                created_by: other, updated_by: other,
                                actions: [{ 'action_name' => 'add_label', 'action_params' => ['spec'] }])
        grant_permissions(*agent_keys)

        patch "/api/v1/macros/#{foreign.id}", params: { name: 'Invadida' }, as: :json

        expect(response).to have_http_status(:not_found)
      end

      it 'still demands macros.manage to edit a GLOBAL macro' do
        grant_permissions(*agent_keys)

        patch "/api/v1/macros/#{macro.id}", params: { name: 'Editada' }, as: :json

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe 'message templates' do
    let(:template) { MessageTemplate.create!(name: "t-#{SecureRandom.hex(4)}", content: 'Olá') }

    it 'denies create/update to the agent key set (403) but keeps the list open' do
      grant_permissions(*agent_keys)

      post '/api/v1/message_templates',
           params: { message_template: { name: "n-#{SecureRandom.hex(4)}", content: 'x' } }, as: :json
      expect(response).to have_http_status(:forbidden)

      patch "/api/v1/message_templates/#{template.id}",
            params: { message_template: { content: 'y' } }, as: :json
      expect(response).to have_http_status(:forbidden)

      get '/api/v1/message_templates', as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'allows create/update for a message_templates.manage holder' do
      grant_permissions('message_templates.manage', 'message_templates.read')

      post '/api/v1/message_templates',
           params: { message_template: { name: "g-#{SecureRandom.hex(4)}", content: 'Hello' } }, as: :json
      expect(response).to have_http_status(:created)

      patch "/api/v1/message_templates/#{template.id}",
            params: { message_template: { content: 'edited' } }, as: :json
      expect(response).to have_http_status(:success)
    end
  end
end
