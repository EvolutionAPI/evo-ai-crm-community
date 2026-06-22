class Pipelines::ProcessStageInactivityActionsJob < ApplicationJob
  queue_as :default

  def perform(pipeline_item_id)
    pipeline_item = PipelineItem.find_by(id: pipeline_item_id)
    return if pipeline_item.nil?
    return if pipeline_item.completed_at.present?
    return if pipeline_item.pipeline_stage.nil?

    Pipelines::StageInactivityActionsService.new(pipeline_item).process
  rescue StandardError => e
    Rails.logger.error "[ProcessStageInactivity] item=#{pipeline_item_id}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise e # let Sidekiq retry; the reserve-before-send guard prevents dup sends
  end
end
