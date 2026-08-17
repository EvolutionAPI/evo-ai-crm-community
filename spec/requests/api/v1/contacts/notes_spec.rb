# frozen_string_literal: true

require 'rails_helper'

# Triage repro for the "contact notes do not save / are not displayed" report.
# The card asks two questions: does the write land, and does the read render?
# These examples answer both against the real controller, using the exact
# payloads the contacts screen sends (an unwrapped `{ content }` body).
RSpec.describe 'Api::V1::Contacts::Notes', type: :request do
  let(:user) { User.create!(name: 'Note Probe', email: "note-probe-#{SecureRandom.hex(4)}@example.com") }
  let(:contact) { Contact.create!(name: "Contact #{SecureRandom.hex(3)}") }

  before do
    probe = user
    allow_any_instance_of(Api::BaseController).to receive(:authenticate_request!) do
      Current.user = probe
      Current.evo_permission_cache ||= {}
    end
    allow_any_instance_of(EvoAuthService).to receive(:check_user_permission).and_return(true)
  end

  after { Current.reset }

  def json_response
    JSON.parse(response.body)
  end

  describe 'the write path' do
    it 'persists the note from the unwrapped body the frontend sends' do
      post "/api/v1/contacts/#{contact.id}/notes", params: { content: 'primeira nota' }, as: :json

      expect(response).to have_http_status(:created)
      expect(contact.notes.reload.map(&:content)).to contain_exactly('primeira nota')
    end
  end

  describe 'the response envelope' do
    let!(:note) { Note.create!(content: 'nota existente', contact: contact, user: user) }

    it 'answers the index in the standard envelope the frontend unwraps' do
      get "/api/v1/contacts/#{contact.id}/notes", as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response).to be_a(Hash)
      expect(json_response['data'].map { |n| n['content'] }).to contain_exactly('nota existente')
    end

    it 'answers show in the same envelope' do
      get "/api/v1/contacts/#{contact.id}/notes/#{note.id}", as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response).to be_a(Hash)
      expect(json_response.dig('data', 'content')).to eq('nota existente')
    end

    it 'answers create in the same envelope' do
      post "/api/v1/contacts/#{contact.id}/notes", params: { content: 'nova nota' }, as: :json

      expect(response).to have_http_status(:created)
      expect(json_response).to be_a(Hash)
      expect(json_response.dig('data', 'content')).to eq('nova nota')
    end

    it 'answers update in the same envelope' do
      patch "/api/v1/contacts/#{contact.id}/notes/#{note.id}", params: { content: 'nota editada' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response).to be_a(Hash)
      expect(json_response.dig('data', 'content')).to eq('nota editada')
    end

    it 'answers destroy in the same envelope' do
      delete "/api/v1/contacts/#{contact.id}/notes/#{note.id}", as: :json

      expect(response).to have_http_status(:ok)
      expect(json_response).to be_a(Hash)
      expect(json_response['success']).to be(true)
      expect(Note.exists?(note.id)).to be(false)
    end
  end
end
