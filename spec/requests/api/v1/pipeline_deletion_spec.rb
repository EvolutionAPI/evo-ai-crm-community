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
  end

  after { Current.reset }

  it 'deletes an empty pipeline' do
    expect { delete "/api/v1/pipelines/#{pipeline.id}", as: :json }
      .to change(Pipeline, :count).by(-1)
    expect(response).to have_http_status(:ok)
  end

  it 'deletes a pipeline whose items are all completed' do
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact, completed_at: Time.current)

    expect { delete "/api/v1/pipelines/#{pipeline.id}", as: :json }
      .to change(Pipeline, :count).by(-1)
    expect(response).to have_http_status(:ok)
  end

  it 'refuses to delete a pipeline holding an active item' do
    PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact, completed_at: nil)

    expect { delete "/api/v1/pipelines/#{pipeline.id}", as: :json }
      .not_to change(Pipeline, :count)
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
end
