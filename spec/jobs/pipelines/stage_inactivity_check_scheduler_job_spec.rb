# frozen_string_literal: true

require 'rails_helper'

# EVO-2201: the scheduler runs every minute. Filtering archived pipelines here keeps an
# archived board from enqueueing a job per item forever; the service guards it as well,
# since this filter is an optimisation and not the authority.
RSpec.describe Pipelines::StageInactivityCheckSchedulerJob do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Test Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) do
    Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end

  let(:inactivity_rules) do
    { 'rules' => [{ 'id' => SecureRandom.uuid, 'trigger' => 'inactivity',
                    'trigger_value' => { 'minutes' => 30, 'base' => 'stage_stagnation' },
                    'action' => 'send_direct_message', 'action_value' => 'Still there?' }] }
  end

  def pipeline_with_item(active:)
    pipeline = Pipeline.create!(name: "P #{SecureRandom.hex(3)}", pipeline_type: 'custom', created_by: user)
    stage = PipelineStage.create!(pipeline: pipeline, name: 'A', position: 1, automation_rules: inactivity_rules)
    item = PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)
    pipeline.update!(is_active: false) unless active
    [pipeline, item]
  end

  it 'enqueues a job for an item in an active pipeline' do
    _pipeline, item = pipeline_with_item(active: true)

    expect(Pipelines::ProcessStageInactivityActionsJob).to receive(:perform_later).with(item.id)

    described_class.new.perform
  end

  it 'does not enqueue anything for an item in an archived pipeline' do
    pipeline_with_item(active: false)

    expect(Pipelines::ProcessStageInactivityActionsJob).not_to receive(:perform_later)

    described_class.new.perform
  end

  # The scheduler filter is an optimisation, not the authority: a job enqueued by any other
  # caller must still be refused by the service itself.
  it 'refuses an item in an archived pipeline even when the job is invoked directly' do
    _pipeline, item = pipeline_with_item(active: false)
    item.stage_movements.update_all(created_at: 31.minutes.ago)

    expect { Pipelines::ProcessStageInactivityActionsJob.perform_now(item.id) }
      .not_to change(StageInactivityExecution, :count)
  end

  it 'reports how many items it skipped' do
    pipeline_with_item(active: false)
    allow(Pipelines::ProcessStageInactivityActionsJob).to receive(:perform_later)
    allow(Rails.logger).to receive(:info)

    described_class.new.perform

    expect(Rails.logger).to have_received(:info).with(/1 item skipped in archived pipelines/)
  end

  # The active/archived decision must read the same pipeline the service guard reads —
  # through the stage, not through pipeline_id. Nothing constrains the two columns to agree,
  # so on a drifted row (pipeline_id archived, stage on an active pipeline) a pipeline_id-based
  # filter would drop an item the service would have fired: the active board silently stops.
  it 'honours the stage pipeline, not pipeline_id, when the two disagree' do
    _pipeline, item = pipeline_with_item(active: true)
    archived = Pipeline.create!(name: "Arch #{SecureRandom.hex(3)}", pipeline_type: 'custom', created_by: user)
    archived.update!(is_active: false)
    item.update_columns(pipeline_id: archived.id) # rubocop:disable Rails/SkipsModelValidations

    expect(Pipelines::ProcessStageInactivityActionsJob).to receive(:perform_later).with(item.id)

    described_class.new.perform
  end
end
