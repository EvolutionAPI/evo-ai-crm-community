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

  # EVO-2200: form_slug lives only in the pipeline item's custom_fields, and deleting a
  # kanban card is a hard delete — the form attribution would be lost with it. Mirroring
  # it on the contact keeps the link, and it is a list because one person may fill several.
  describe 'capture form attribution on the contact' do
    let(:email) { "lead-#{SecureRandom.hex(4)}@example.com" }

    # A contact cannot hold two active items in the SAME pipeline (pre-existing rule:
    # "Contact already has an active journey in this pipeline"), so a second capture for
    # the same person necessarily lands in another pipeline.
    let(:other_pipeline) do
      p = Pipeline.create!(name: "Support #{SecureRandom.hex(4)}", pipeline_type: 'support', created_by: user)
      p.pipeline_stages.create!(name: 'New', position: 1)
      p
    end

    def perform_with_form(slug, contact_email, destination: pipeline)
      described_class.new(lead_params: {
        contact: { name: 'Ada', email: contact_email },
        deal: { pipeline_id: destination.id, stage_id: destination.pipeline_stages.first.id },
        metadata: { form_slug: slug, lead_source: 'crm_form' }
      }).perform
    end

    it 'stamps the originating form on the contact' do
      result = perform_with_form('contact-us', email)

      expect(result[:success]).to be(true)
      expect(result[:contact].reload.custom_attributes['capture_form_slugs']).to eq(['contact-us'])
    end

    it 'accumulates every form the same person filled' do
      perform_with_form('contact-us', email)
      result = perform_with_form('newsletter', email, destination: other_pipeline)

      expect(result[:success]).to be(true)
      expect(result[:contact].reload.custom_attributes['capture_form_slugs'])
        .to eq(%w[contact-us newsletter])
    end

    it 'does not duplicate a form the contact already came through' do
      perform_with_form('contact-us', email)
      result = perform_with_form('contact-us', email, destination: other_pipeline)

      expect(result[:success]).to be(true)
      expect(result[:contact].reload.custom_attributes['capture_form_slugs']).to eq(['contact-us'])
    end

    it 'leaves the contact untouched when the capture carries no form' do
      result = perform(contact: { name: 'Ada', email: email })

      expect(result[:contact].reload.custom_attributes).not_to have_key('capture_form_slugs')
    end

    it 'survives deletion of the pipeline item, unlike the item custom_fields' do
      result = perform_with_form('contact-us', email)
      result[:pipeline_item].destroy!

      expect(result[:contact].reload.custom_attributes['capture_form_slugs']).to eq(['contact-us'])
    end
  end

  describe 'archived destination pipeline' do
    let(:email) { "lead-#{SecureRandom.hex(4)}@example.com" }

    # Declined C1/C2/C3 on EVO-2200: capture proceeds, because the form's Leads tab does
    # not filter is_active and the record stays visible and recoverable.
    it 'still captures the lead' do
      pipeline.update!(is_active: false)

      result = perform(contact: { name: 'Ada', email: email })

      expect(result[:success]).to be(true)
      expect(result[:pipeline_item]).to be_present
    end

    it 'logs the archived destination so the proceed is observable' do
      pipeline.update!(is_active: false)
      allow(Rails.logger).to receive(:warn)

      perform(contact: { name: 'Ada', email: email })

      expect(Rails.logger).to have_received(:warn).with(/archived pipeline #{pipeline.id}/)
    end

    it 'stays quiet while the pipeline is active' do
      allow(Rails.logger).to receive(:warn)

      perform(contact: { name: 'Ada', email: email })

      expect(Rails.logger).not_to have_received(:warn).with(/archived pipeline/)
    end
  end
end
