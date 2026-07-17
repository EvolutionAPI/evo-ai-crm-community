class EvolutionGo::HealthMonitorJob < MutexApplicationJob
  queue_as :scheduled_jobs

  def perform(monitor_id)
    monitor = EvolutionGoHealthMonitor.find(monitor_id)
    with_lock("evolution-go-health-monitor:#{monitor_id}") do
      EvolutionGo::HealthMonitorService.new(monitor).perform
    end
  rescue ActiveRecord::RecordNotFound
    # Monitor was deleted between enqueue and perform; safe to skip.
  end
end
