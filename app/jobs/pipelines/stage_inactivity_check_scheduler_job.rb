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
    # this is an optimisation and not the authority. Resolved through the stage
    # (pipeline_stage -> pipeline) — the same source the service guard reads — so the filter
    # and the authority read the same pipeline and cannot disagree on a drifted row.
    #
    # Counted on the archived side only — this runs every minute and that side is empty in
    # the normal case, so the common path pays for one narrow count instead of two wide ones.
    skipped = candidates.joins(pipeline_stage: :pipeline).where(pipelines: { is_active: false }).count
    summary = "[StageInactivityScheduler] #{stage_ids.size} stages with inactivity rules"
    summary += ", #{skipped} item#{'s' if skipped != 1} skipped in archived pipelines" if skipped.positive?
    Rails.logger.info(summary)

    candidates.joins(pipeline_stage: :pipeline)
              .where(pipelines: { is_active: true })
              .find_each(batch_size: 100) do |item|
      Pipelines::ProcessStageInactivityActionsJob.perform_later(item.id)
    end
  end
end
