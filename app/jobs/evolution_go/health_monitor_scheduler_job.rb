class EvolutionGo::HealthMonitorSchedulerJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    EvolutionGoHealthMonitor.enabled.pluck(:id).each do |monitor_id|
      EvolutionGo::HealthMonitorJob.perform_later(monitor_id)
    end
  end
end
