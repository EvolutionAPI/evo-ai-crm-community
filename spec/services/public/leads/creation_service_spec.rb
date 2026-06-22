# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Public::Leads::CreationService do
  let(:user) { User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: 'Owner') }
  let(:pipeline) { Pipeline.create!(name: "Sales #{SecureRandom.hex(4)}", pipeline_type: 'sales', created_by: user) }
  let!(:stage) { pipeline.pipeline_stages.create!(name: 'New', position: 1) }

  def perform(contact:, custom_attributes: nil)
    contact = contact.merge(custom_attributes: custom_attributes) if custom_attributes
    described_class.new(lead_params: {
      contact: contact,
      deal: { pipeline_id: pipeline.id, stage_id: stage.id }
    }).perform
  end

  describe 'anonymous custom_attributes write' do
    let(:email) { "lead-#{SecureRandom.hex(4)}@example.com" }

    it 'sets custom attributes when creating a new contact' do
      result = perform(contact: { name: 'Ada', email: email }, custom_attributes: { 'city' => 'Porto Alegre' })

      expect(result[:success]).to be(true)
      expect(result[:contact].custom_attributes['city']).to eq('Porto Alegre')
    end

    it 'does not overwrite an existing contact\'s custom attributes, only fills blank keys' do
      existing = Contact.create!(
        name: 'Ada', email: email,
        custom_attributes: { 'city' => 'São Paulo', 'plan' => 'gold' }
      )

      result = perform(
        contact: { name: 'Ada', email: email },
        custom_attributes: { 'city' => 'Hacked', 'plan' => '', 'segment' => 'enterprise' }
      )

      expect(result[:success]).to be(true)
      existing.reload
      # Pre-existing values are preserved against the anonymous submitter…
      expect(existing.custom_attributes['city']).to eq('São Paulo')
      expect(existing.custom_attributes['plan']).to eq('gold')
      # …while genuinely new keys are still captured.
      expect(existing.custom_attributes['segment']).to eq('enterprise')
    end
  end
end
