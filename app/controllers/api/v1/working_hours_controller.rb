class Api::V1::WorkingHoursController < Api::V1::BaseController
  require_permissions({
    index: 'working_hours.read',
    show: 'working_hours.read',
    create: 'working_hours.write',
    update: 'working_hours.write',
    destroy: 'working_hours.delete'
  })
  
  before_action :fetch_webhook, only: [:update]

  def update
    @working_hour.update!(working_hour_params)
    
    success_response(
      data: WorkingHourSerializer.serialize(@working_hour),
      message: 'Working hours updated successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message
    )
  end

  private

  def working_hour_params
    params.require(:working_hour).permit(:inbox_id, :open_hour, :open_minutes, :close_hour, :close_minutes, :closed_all_day)
  end

  def fetch_working_hour
    @working_hour = WorkingHour.find(params[:id])
  end
end
