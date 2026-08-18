# frozen_string_literal: true

require 'rails_helper'
require 'yaml'

# Permission-level proof for the pipeline card-write gate (card #178).
# PipelineItemsController authorizes its WRITE_ACTIONS via PipelinePolicy#update_items?,
# which requires the dedicated `pipeline_items.update` permission — NOT the
# manager-level `pipelines.update`. This guards against a future edit silently
# re-coupling card writes to pipelines.update (the over-grant that let an agent
# archive the funnel) or dropping the key from the catalog.
RSpec.describe 'Pipeline card-write permission (pipeline_items.update)', type: :request do
  let(:user) { User.create!(name: 'Perm Probe', email: "probe-#{SecureRandom.hex(4)}@example.com") }
  # Public pipeline so accessible_record? passes for any user — isolates the
  # permission check from the visibility check.
  let(:pipeline) do
    Pipeline.create!(name: 'Sales', pipeline_type: 'sales', visibility: :public, created_by: user)
  end

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
  end

  after { Current.reset }

  # Stubs the permission seam (User#has_permission? -> PermissionResolver ->
  # EvoAuthService#check_user_permission) to a literal allow-list.
  def grant_permissions(*granted)
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission) do |_svc, _uid, permission|
      granted.include?(permission)
    end
  end

  let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'New', position: 1) }
  # PipelineItem requires a conversation or a contact — a contact is the cheapest.
  let(:card_contact) { Contact.create!(name: "Card #{SecureRandom.hex(3)}") }
  let(:card) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: card_contact) }

  # A real card create: a contact placed on the pipeline's first stage. Needs a
  # stage to exist, so touch `stage`.
  def create_card
    stage
    contact = Contact.create!(name: "Lead #{SecureRandom.hex(3)}")
    post "/api/v1/pipelines/#{pipeline.id}/pipeline_items",
         params: { type: 'contact', item_id: contact.id }, as: :json
  end

  it 'DENIES a card write to a user without pipeline_items.update' do
    grant_permissions('pipelines.read')

    expect { create_card }.not_to change(PipelineItem, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'DENIES a card write to a holder of pipelines.update but NOT pipeline_items.update (the split is real)' do
    # Before card #178, granting pipelines.update was the only way to unblock the
    # card — but it also unlocked archive/set_as_default. It must NOT imply card writes.
    grant_permissions('pipelines.read', 'pipelines.update')

    expect { create_card }.not_to change(PipelineItem, :count)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'AUTHORIZES the create for a holder of pipeline_items.update — the card is created (2xx)' do
    grant_permissions('pipelines.read', 'pipeline_items.update')

    expect { create_card }.to change(PipelineItem, :count).by(1)
    expect(response).to have_http_status(:success)
  end

  describe 'move_to_stage is a card write (pipeline_items.update), not manager-level' do
    it 'AUTHORIZES move_to_stage for a holder of pipeline_items.update (gate opens)' do
      target = PipelineStage.create!(pipeline: pipeline, name: 'Won', position: 2)
      grant_permissions('pipelines.read', 'pipeline_items.update')

      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{card.id}/move_to_stage",
            params: { pipeline_stage_id: target.id }, as: :json

      # The authorization gate opened (Pundit would 401 without the key); the
      # move itself resolves the card via the conversation-first lookup, out of
      # scope for this authz spec.
      expect(response).not_to have_http_status(:unauthorized)
    end

    it 'DENIES move_to_stage without pipeline_items.update' do
      grant_permissions('pipelines.read')

      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{card.id}/move_to_stage",
            params: { pipeline_stage_id: stage.id }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # CRM-178 review (achado 2): deleting a card cascades to its
  # stage_movements/tasks/products, so `destroy` must stay MANAGER-level
  # (pipelines.update) — the agent's pipeline_items.update must NOT unlock it, the
  # same way CRM-182 kept deletes off the agent.
  describe 'DELETE (destroy) stays manager-level — the agent key does NOT unlock it' do
    it 'DENIES destroy to a holder of pipeline_items.update (agent) and keeps the card' do
      card
      grant_permissions('pipelines.read', 'pipeline_items.update')

      delete "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{card.id}", as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(PipelineItem.exists?(card.id)).to be(true)
    end

    it 'ALLOWS destroy for a holder of pipelines.update (manager)' do
      card
      grant_permissions('pipelines.read', 'pipelines.update')

      delete "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{card.id}", as: :json

      expect(response).not_to have_http_status(:unauthorized)
    end
  end

  # CRM-178 review (achado 5): `update_conversation` was defined as the typo
  # `update_notesconversation`, so PATCH .../update_conversation reached no action and
  # the body never ran. Fixing the name makes a never-executed endpoint live, so it
  # gets covered here — gate AND effect — instead of shipping on inspection alone.
  describe 'update_conversation (route was dead until CRM-178) is a card write' do
    let(:target_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Won', position: 2) }

    it 'DENIES update_conversation without pipeline_items.update' do
      card
      grant_permissions('pipelines.read')

      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{card.id}/update_conversation",
            params: { stage_id: target_stage.id }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(card.reload.pipeline_stage_id).to eq(stage.id)
    end

    it 'MOVES the card and persists the note for a holder of pipeline_items.update' do
      card
      grant_permissions('pipelines.read', 'pipeline_items.update')

      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/#{card.id}/update_conversation",
            params: { stage_id: target_stage.id, notes: 'moved by the agent' }, as: :json

      expect(response).to have_http_status(:success)
      expect(card.reload.pipeline_stage_id).to eq(target_stage.id)
      # Not `.last`: stage_movements has a uuid PK, so an unordered #last is not
      # chronological. The note landing on any movement is the claim under test.
      expect(card.stage_movements.pluck(:notes)).to include('moved by the agent')
    end
  end

  # CRM-178 review (achado 3): a cross-pipeline move REMOVES the card from its previous
  # pipeline, and the action only authorized the pipeline named in the URL. With card
  # writes now agent-level, that let an agent pull a card out of a funnel it cannot see
  # by naming one it can.
  describe 'move_conversation authorizes the SOURCE pipeline too' do
    let(:other_user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
    let(:channel) { Channel::WebWidget.create!(website_url: 'https://crm178.example.com') }
    let(:inbox) { Inbox.create!(name: "Inbox #{SecureRandom.hex(3)}", channel: channel) }
    let(:conversation_contact) { Contact.create!(name: "Contact #{SecureRandom.hex(3)}") }
    let(:contact_inbox) do
      ContactInbox.create!(inbox: inbox, contact: conversation_contact, source_id: SecureRandom.hex(8))
    end
    let(:conversation) do
      Conversation.create!(inbox: inbox, contact: conversation_contact, contact_inbox: contact_inbox)
    end

    # Private and owned by someone else: outside PipelinePolicy::Scope for our probe.
    let(:private_pipeline) do
      Pipeline.create!(name: 'Diretoria', pipeline_type: 'sales', visibility: :private, created_by: other_user)
    end
    let(:private_stage) { PipelineStage.create!(pipeline: private_pipeline, name: 'Held', position: 1) }
    let!(:private_card) do
      PipelineItem.create!(pipeline: private_pipeline, pipeline_stage: private_stage, conversation: conversation)
    end

    def move_into_target
      stage
      patch "/api/v1/pipelines/#{pipeline.id}/pipeline_items/move_conversation",
            params: { conversation_id: conversation.id, pipeline_stage_id: stage.id }, as: :json
    end

    it 'DENIES pulling a card out of a pipeline the caller cannot see, and leaves it there' do
      grant_permissions('pipelines.read', 'pipeline_items.update')

      move_into_target

      expect(response).to have_http_status(:unauthorized)
      expect(private_card.reload.pipeline_id).to eq(private_pipeline.id)
    end

    it 'ALLOWS the relocate when the source pipeline IS accessible' do
      private_pipeline.update!(visibility: :public)
      grant_permissions('pipelines.read', 'pipeline_items.update')

      move_into_target

      expect(response).not_to have_http_status(:unauthorized)
      expect(private_card.reload.pipeline_id).to eq(pipeline.id)
    end
  end

  it 'gates on a permission key that exists in the auth catalog mirror' do
    catalog = YAML.safe_load_file(Rails.root.join('spec/fixtures/rbac/permission_catalog.yml')).to_set
    expect(catalog).to include('pipeline_items.update')
  end
end
