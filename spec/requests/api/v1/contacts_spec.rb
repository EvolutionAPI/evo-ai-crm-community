# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/contacts', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) do
    {
      'X-Service-Token' => service_token
    }
  end

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  it 'creates contact with one label and persists it' do
    post '/api/v1/contacts',
         params: { name: 'John One', email: 'john-one@example.com', labels: ['vip'] },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    created_contact = Contact.find_by(email: 'john-one@example.com')
    expect(created_contact).to be_present
    expect(created_contact.label_list).to eq(['vip'])
  end

  it 'creates contact with multiple labels and persists them normalized' do
    post '/api/v1/contacts',
         params: { name: 'John Multi', email: 'john-multi@example.com', labels: [' vip ', 'sales'] },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    created_contact = Contact.find_by(email: 'john-multi@example.com')
    expect(created_contact).to be_present
    expect(created_contact.label_list).to match_array(%w[vip sales])
  end

  it 'creates contact without labels preserving existing behavior' do
    post '/api/v1/contacts',
         params: { name: 'John Plain', email: 'john-plain@example.com' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:created)
    created_contact = Contact.find_by(email: 'john-plain@example.com')
    expect(created_contact).to be_present
    expect(created_contact.label_list).to eq([])
  end

  it 'returns controlled 4xx for malformed labels payload' do
    post '/api/v1/contacts',
         params: { name: 'Invalid Labels', email: 'invalid-labels@example.com', labels: 'vip' },
         headers: headers,
         as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(json_response.dig('error', 'code')).to eq('INVALID_PARAMETER')
  end
end

RSpec.describe Api::V1::ContactsController, type: :controller do
  describe '#listable_contacts' do
    subject(:listable_contact_ids) { controller.send(:listable_contacts).pluck(:id) }

    let!(:resolved_contact) { Contact.create!(name: 'Has Email', email: 'has-email@example.com') }
    let!(:name_only_contact) { Contact.create!(name: 'Name Only Contact') }
    let!(:blank_name_contact) { Contact.create!(name: '   ') }

    before do
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new)
    end

    after do
      Current.reset
    end

    it 'includes contacts with resolved identity and contacts with only name' do
      expect(listable_contact_ids).to include(resolved_contact.id, name_only_contact.id)
      expect(listable_contact_ids).not_to include(blank_name_contact.id)
    end
  end

  describe '#invalid_contact_labels_payload?' do
    subject(:invalid_payload) { controller.send(:invalid_contact_labels_payload?) }

    before do
      allow(controller).to receive(:params).and_return(ActionController::Parameters.new(raw_params))
      allow(controller).to receive(:permitted_params).and_return(ActionController::Parameters.new(permitted_params))
    end

    context 'when labels is a string in raw payload' do
      let(:raw_params) { { labels: 'vip' } }
      let(:permitted_params) { {} }

      it 'returns true' do
        expect(invalid_payload).to be(true)
      end
    end

    context 'when labels contains blank values' do
      let(:raw_params) { { labels: ['vip', ' '] } }
      let(:permitted_params) { { labels: ['vip', ' '] } }

      it 'returns true' do
        expect(invalid_payload).to be(true)
      end
    end

    context 'when labels is a valid string array' do
      let(:raw_params) { { labels: [' vip ', 'sales'] } }
      let(:permitted_params) { { labels: [' vip ', 'sales'] } }

      it 'returns false' do
        expect(invalid_payload).to be(false)
      end
    end
  end

  describe '#contact_create_params' do
    subject(:create_params) { controller.send(:contact_create_params) }

    before do
      allow(controller).to receive(:permitted_params).and_return(
        ActionController::Parameters.new(
          name: 'John',
          email: 'john@example.com',
          labels: [' vip ', 'sales'],
          avatar_url: 'https://example.com/avatar.png',
          company_ids: ['1']
        )
      )
    end

    it 'maps labels to label_list and removes unsupported keys' do
      expect(create_params.to_unsafe_h).to include('name' => 'John', 'email' => 'john@example.com')
      expect(create_params[:label_list]).to eq(['vip', 'sales'])
      expect(create_params).not_to have_key(:labels)
      expect(create_params).not_to have_key(:avatar_url)
      expect(create_params).not_to have_key(:company_ids)
    end
  end
end

RSpec.describe 'Api::V1::ContactsController', type: :request do
  describe 'DELETE /api/v1/contacts/:id' do
    let(:user) { User.create!(email: "contacts-delete-#{SecureRandom.hex(4)}@example.com", name: 'Test User') }
    let(:contact) { Contact.create!(name: 'Test Contact', email: 'contact@example.com') }
    let(:headers) do
      {
        'X-Service-Token' => 'spec-service-token'
      }
    end

    before do
      ENV['EVOAI_CRM_API_TOKEN'] = 'spec-service-token'
      Current.user = user
    end

    after do
      ENV.delete('EVOAI_CRM_API_TOKEN')
      Current.reset
    end

    context 'when contact has pipeline items directly linked (leads)' do
      let!(:pipeline) { Pipeline.create!(name: 'Test Pipeline', pipeline_type: 'sales', created_by: user) }
      let!(:pipeline_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage 1', position: 1) }
      let!(:pipeline_item) do
        PipelineItem.create!(
          pipeline: pipeline,
          pipeline_stage: pipeline_stage,
          contact: contact,
          entered_at: Time.current
        )
      end

      it 'deletes the contact and removes all directly linked pipeline items' do
        expect(PipelineItem.exists?(pipeline_item.id)).to be true

        delete "/api/v1/contacts/#{contact.id}", headers: headers

        expect(response).to have_http_status(:ok)
        expect(Contact.exists?(contact.id)).to be false
        expect(PipelineItem.exists?(pipeline_item.id)).to be false
      end
    end

    context 'when contact has pipeline items linked via conversations (deals)' do
      let!(:channel_deals) { Channel::Api.create! }
      let!(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel_deals) }
      let!(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
      let!(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
      let!(:pipeline) { Pipeline.create!(name: 'Test Pipeline', pipeline_type: 'custom', created_by: user) }
      let!(:pipeline_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage 1', position: 1) }
      let!(:pipeline_item) do
        PipelineItem.create!(
          pipeline: pipeline,
          pipeline_stage: pipeline_stage,
          conversation: conversation,
          entered_at: Time.current
        )
      end

      it 'deletes the contact and removes all pipeline items linked via conversations' do
        expect(PipelineItem.exists?(pipeline_item.id)).to be true
        expect(pipeline_item.conversation_id).to eq(conversation.id)

        delete "/api/v1/contacts/#{contact.id}", headers: headers

        expect(response).to have_http_status(:ok)
        expect(Contact.exists?(contact.id)).to be false
        expect(PipelineItem.exists?(pipeline_item.id)).to be false
      end
    end

    context 'when contact has both direct and conversation-linked pipeline items' do
      let!(:channel_both) { Channel::Api.create! }
      let!(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel_both) }
      let!(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
      let!(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
      let!(:lead_pipeline) { Pipeline.create!(name: 'Lead Pipeline', pipeline_type: 'sales', created_by: user) }
      let!(:deal_pipeline) { Pipeline.create!(name: 'Deal Pipeline', pipeline_type: 'custom', created_by: user) }
      let!(:lead_stage) { PipelineStage.create!(pipeline: lead_pipeline, name: 'Stage 1', position: 1) }
      let!(:deal_stage) { PipelineStage.create!(pipeline: deal_pipeline, name: 'Stage 1', position: 1) }
      let!(:lead_item) do
        PipelineItem.create!(
          pipeline: lead_pipeline,
          pipeline_stage: lead_stage,
          contact: contact,
          entered_at: Time.current
        )
      end
      let!(:deal_item) do
        PipelineItem.create!(
          pipeline: deal_pipeline,
          pipeline_stage: deal_stage,
          conversation: conversation,
          entered_at: Time.current
        )
      end

      it 'deletes the contact and removes all related pipeline items (both types)' do
        expect(PipelineItem.exists?(lead_item.id)).to be true
        expect(PipelineItem.exists?(deal_item.id)).to be true

        delete "/api/v1/contacts/#{contact.id}", headers: headers

        expect(response).to have_http_status(:ok)
        expect(Contact.exists?(contact.id)).to be false
        expect(PipelineItem.exists?(lead_item.id)).to be false
        expect(PipelineItem.exists?(deal_item.id)).to be false
      end
    end

    context 'when contact has no pipeline items' do
      it 'deletes the contact successfully' do
        delete "/api/v1/contacts/#{contact.id}", headers: headers

        expect(response).to have_http_status(:ok)
        expect(Contact.exists?(contact.id)).to be false
      end
    end

    context 'when contact has messages with attachments (EVO-973 regression)' do
      let!(:channel_att) { Channel::Api.create! }
      let!(:inbox_att) { Inbox.create!(name: 'Attachment Inbox', channel: channel_att) }
      let!(:contact_inbox_att) { ContactInbox.create!(contact: contact, inbox: inbox_att, source_id: SecureRandom.hex(8)) }
      let!(:conversation_att) { Conversation.create!(inbox: inbox_att, contact: contact, contact_inbox: contact_inbox_att) }
      let!(:message_att) do
        Message.create!(
          conversation: conversation_att,
          inbox: inbox_att,
          content: 'media',
          message_type: :incoming,
          sender: contact
        )
      end
      let!(:attachment) do
        Attachment.create!(
          attachable: message_att,
          file_type: :image,
          external_url: 'https://example.com/test.jpg'
        )
      end

      it 'deletes contact and cascades through message attachments without PG::UndefinedColumn' do
        delete "/api/v1/contacts/#{contact.id}", headers: headers

        expect(response).to have_http_status(:ok)
        expect(Contact.exists?(contact.id)).to be false
        expect(Attachment.exists?(attachment.id)).to be false
      end
    end

    context 'when contact deletion fails due to foreign key constraint' do
      let!(:channel_fk) { Channel::Api.create! }
      let!(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel_fk) }
      let!(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: SecureRandom.hex(8)) }
      let!(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

      before do
        allow_any_instance_of(Contact).to receive(:destroy!).and_raise(
          ActiveRecord::StatementInvalid.new('PG::ForeignKeyViolation: foreign key constraint violation')
        )
      end

      it 'returns error response with OPERATION_NOT_ALLOWED code' do
        delete "/api/v1/contacts/#{contact.id}", headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        json_data = JSON.parse(response.body)
        expect(json_data['success']).to be false
        expect(json_data['error']['code']).to eq('OPERATION_NOT_ALLOWED')
        expect(json_data['error']['message']).to include('associated records that prevent deletion')
      end
    end

    context 'when contact cannot be destroyed due to validation errors' do
      before do
        contact.errors.add(:base, 'Cannot delete contact with active subscriptions')
        allow_any_instance_of(Contact).to receive(:destroy!).and_raise(
          ActiveRecord::RecordNotDestroyed.new('Contact could not be destroyed', contact)
        )
      end

      it 'returns error response with validation errors' do
        delete "/api/v1/contacts/#{contact.id}", headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        json_data = JSON.parse(response.body)
        expect(json_data['success']).to be false
        expect(json_data['error']['code']).to eq('OPERATION_NOT_ALLOWED')
        expect(json_data['error']['message']).to include('Cannot delete contact')
        expect(json_data['error']['details']['errors']).to be_present
      end
    end
  end

  describe 'AC2: Pipeline list endpoints after contact deletion' do
    let(:user) { User.create!(email: "contacts-ac2-#{SecureRandom.hex(4)}@example.com", name: 'Test User') }
    let(:contact) { Contact.create!(name: 'Test Contact', email: 'contact@example.com') }
    let(:pipeline) { Pipeline.create!(name: 'Test Pipeline', pipeline_type: 'sales', created_by: user) }
    let(:pipeline_stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage 1', position: 1) }
    let(:headers) do
      {
        'X-Service-Token' => 'spec-service-token'
      }
    end

    before do
      ENV['EVOAI_CRM_API_TOKEN'] = 'spec-service-token'
      Current.user = user
    end

    after do
      ENV.delete('EVOAI_CRM_API_TOKEN')
      Current.reset
    end

    it 'removes pipeline items linked to contact after contact deletion' do
      pipeline_item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact,
        entered_at: Time.current
      )

      delete "/api/v1/contacts/#{contact.id}", headers: headers
      expect(response).to have_http_status(:ok)

      expect(PipelineItem.exists?(pipeline_item.id)).to be false
    end

    it 'contact deletion cleans up associated pipeline items' do
      pipeline_item = PipelineItem.create!(
        pipeline: pipeline,
        pipeline_stage: pipeline_stage,
        contact: contact,
        entered_at: Time.current
      )

      delete "/api/v1/contacts/#{contact.id}", headers: headers
      expect(response).to have_http_status(:ok)

      expect(PipelineItem.exists?(pipeline_item.id)).to be false
      expect(Contact.exists?(contact.id)).to be false
    end
  end
end

RSpec.describe 'GET /api/v1/contacts/companies_list', type: :request do
  let(:user) { User.create!(email: "companies-list-#{SecureRandom.hex(4)}@example.com", name: 'Test User') }
  let(:headers) { { 'X-Service-Token' => 'spec-service-token' } }

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = 'spec-service-token'
    Current.user = user
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  # EVO-1887: a company is a structural entity, so it must be selectable even
  # without email/phone/identifier (previously hidden by resolved_contacts).
  it 'returns companies without contact info' do
    bare = Contact.create!(name: 'Bare Co', type: 'company')
    Contact.create!(name: 'Just a person', email: "p-#{SecureRandom.hex(4)}@example.com", type: 'person')

    get '/api/v1/contacts/companies_list', headers: headers

    expect(response).to have_http_status(:ok)
    payload = JSON.parse(response.body)['data']
    names = payload.map { |c| c['name'] }
    ids = payload.map { |c| c['id'] }
    expect(names).to include('Bare Co')
    expect(names).not_to include('Just a person')
    expect(ids).to include(bare.id)
  end
end
