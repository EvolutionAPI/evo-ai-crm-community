class Api::V1::EvolutionGo::HealthMonitorsController < Api::V1::BaseController
  require_permissions({
    index: 'inboxes.read',
    create: 'inboxes.update',
    update: 'inboxes.update',
    destroy: 'inboxes.update',
    test: 'inboxes.update'
  })

  before_action :set_monitor, only: [:update, :destroy, :test]

  def index
    render json: { success: true, data: EvolutionGoHealthMonitor.order(created_at: :desc).map { |monitor| serialize(monitor) } }
  end

  def create
    monitor = EvolutionGoHealthMonitor.create!(monitor_params)
    render json: { success: true, data: serialize(monitor) }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def update
    @monitor.update!(monitor_params)
    render json: { success: true, data: serialize(@monitor) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def destroy
    @monitor.destroy!
    head :no_content
  end

  def test
    EvolutionGo::HealthMonitorJob.perform_later(@monitor)
    render json: { success: true, message: 'Health check queued' }, status: :accepted
  end

  private

  def set_monitor
    @monitor = EvolutionGoHealthMonitor.find(params[:id])
  end

  def monitor_params
    params.require(:health_monitor).permit(
      :observed_channel_id, :notification_channel_id, :recipient_number,
      :enabled, :failure_threshold, :recovery_threshold, :cooldown_minutes
    )
  end

  def serialize(monitor)
    monitor.as_json(
      only: [:id, :observed_channel_id, :notification_channel_id, :recipient_number, :enabled,
             :failure_threshold, :recovery_threshold, :cooldown_minutes, :last_state,
             :consecutive_failures, :consecutive_successes, :last_checked_at, :last_alerted_at,
             :last_error, :created_at, :updated_at]
    )
  end
end
