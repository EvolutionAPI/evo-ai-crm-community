# frozen_string_literal: true

require 'rails_helper'

# EVO-2205: destroy blocked on ANY pipeline_item while claiming "active conversations".
# A pipeline whose deals are all completed now deletes; only active items block it.
RSpec.describe 'Pipeline deletion', type: :request do
  let(:user) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let!(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(3)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }
  let(:contact) { Contact.create!(name: 'Lead', email: "lead-#{SecureRandom.hex(4)}@example.com") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(true)
    # EVO-2204: destroy now authorizes the pipeline, and the policy asks the User seam,
    # not the controller one stubbed above — unstubbed it resolves for real and fails
    # closed. `user` is the creator, so visibility passes and these specs stay about
    # deletion.
    allow_any_instance_of(User).to receive(:has_permission?).and_return(true)
  end

  after { Current.reset }

  it 'deletes an empty pipeline' do
    expect { delete "/api/v1/pipelines/#{pipeline.id}", as: :json }
      .to change(Pipeline, :count).by(-1)
    expect(response).to have_http_status(:ok)
  end

  # Deleting the pipeline takes the completed item down with it — `Pipeline has_many
  # :pipeline_items, dependent: :destroy`, and the item's stage_movements/tasks/products
  # go with it. That destruction is the whole reason "should completed items block
  # deletion?" is a product question; assert it so a future change to `dependent:`
  # (soft-delete, :restrict_with_error, a confirmation step) fails here loudly instead
  # of silently changing what a delete costs.
  it 'deletes a pipeline whose items are all completed, destroying those items' do
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact, completed_at: Time.current)

    expect { delete "/api/v1/pipelines/#{pipeline.id}", as: :json }
      .to change(Pipeline, :count).by(-1)
      .and change(PipelineItem, :count).by(-1)
    expect(response).to have_http_status(:ok)
  end

  it 'refuses to delete a pipeline holding an active item' do
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact, completed_at: nil)

    expect { delete "/api/v1/pipelines/#{pipeline.id}", as: :json }
      .not_to change(Pipeline, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']['code']).to eq('CANNOT_DELETE_PIPELINE_WITH_CONVERSATIONS')
    # The message is the point of EVO-2205: it claimed "active conversations" while the
    # guard blocked on any item. Pin the text, or the card's fix can regress unnoticed.
    expect(response.parsed_body['error']['message']).to eq('Cannot delete pipeline with active items')
  end

  # The realistic shape: a contact closed once and came back. Both the partial index
  # (idx_pipeline_items_active_contact_per_pipeline, UNIQUE only WHERE completed_at IS
  # NULL) and the model's uniqueness validation allow the same contact to hold one
  # completed item and one active item in the same pipeline — so `.active` has to filter
  # rather than just count, and the completed sibling must not soften the block.
  it 'refuses to delete a pipeline mixing a completed and an active item' do
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact, completed_at: Time.current)
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact, completed_at: nil)

    expect { delete "/api/v1/pipelines/#{pipeline.id}", as: :json }
      .not_to change(Pipeline, :count)
    expect(pipeline.pipeline_items.count).to eq(2)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']['code']).to eq('CANNOT_DELETE_PIPELINE_WITH_CONVERSATIONS')
  end

  # A contact-only lead (no conversation) is still an active item, so it blocks too —
  # and its presence is why the message says "items", not "conversations".
  it 'refuses to delete a pipeline holding an active contact-only item' do
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact,
                         conversation: nil, completed_at: nil)

    expect { delete "/api/v1/pipelines/#{pipeline.id}", as: :json }
      .not_to change(Pipeline, :count)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  # `require_permissions` gates destroy behind `pipelines.delete` (pipelines_controller.rb:9),
  # and every example above stubs the permission to true — so nothing here exercised the gate.
  # The pipeline is empty on purpose: with an active item present, a refusal would be
  # indistinguishable from the active-items guard doing the work.
  it 'keeps deletion behind pipelines.delete' do
    allow_any_instance_of(Api::BaseController).to receive(:has_user_permission?).and_return(false)

    expect { delete "/api/v1/pipelines/#{pipeline.id}", as: :json }
      .not_to change(Pipeline, :count)
    expect(response).to have_http_status(:forbidden)
  end
end
