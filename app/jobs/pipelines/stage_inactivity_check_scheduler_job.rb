# Runs every minute. Finds pipeline stages that carry at least one `inactivity`
# automation rule, then enqueues a per-item job for the active items in those
# stages. The fine-grained "has enough time elapsed?" decision lives in the
# service; here we only coarse-filter to avoid scanning every pipeline_item.
class Pipelines::StageInactivityCheckSchedulerJob < ApplicationJob
  queue_as :scheduled_jobs

  # JSONB containment: stage has a rule whose trigger == 'inactivity'.
  HAS_INACTIVITY_RULE = "automation_rules @> ?".freeze
  CONTAINMENT = { rules: [{ trigger: 'inactivity' }] }.to_json.freeze

  def perform
    stage_ids = PipelineStage.where(HAS_INACTIVITY_RULE, CONTAINMENT).pluck(:id)
    return if stage_ids.empty?

    candidates = PipelineItem.where(pipeline_stage_id: stage_ids, completed_at: nil)
    # Archived pipelines stop acting on their own (EVO-2201). Filtered here so an archived
    # board does not enqueue a job per item every minute; the service guards it too, since
    # this is an optimisation and not the authority.
    live = candidates.joins(:pipeline).where(pipelines: { is_active: true })

    Rails.logger.info(
      "[StageInactivityScheduler] #{stage_ids.size} stages with inactivity rules, " \
      "#{candidates.count - live.count} items skipped in archived pipelines"
    )

    live.find_each(batch_size: 100) do |item|
      Pipelines::ProcessStageInactivityActionsJob.perform_later(item.id)
    end
  end
end
