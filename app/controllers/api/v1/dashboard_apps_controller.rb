class Api::V1::DashboardAppsController < Api::V1::BaseController
  require_permissions({
    index: 'dashboard_apps.read',
    show: 'dashboard_apps.read',
    create: 'dashboard_apps.write',
    update: 'dashboard_apps.write',
    destroy: 'dashboard_apps.delete'
  })

  before_action :fetch_dashboard_apps, except: [:create]
  before_action :fetch_dashboard_app, only: [:show, :update, :destroy]

  def index
    success_response(
      data: DashboardAppSerializer.serialize_collection(@dashboard_apps),
      message: 'Dashboard apps retrieved successfully'
    )
  end

  def show
    success_response(
      data: DashboardAppSerializer.serialize(@dashboard_app),
      message: 'Dashboard app retrieved successfully'
    )
  end

  def create
    @dashboard_app = DashboardApp.create!(
      permitted_payload.merge(user_id: Current.user.id)
    )
    
    success_response(
      data: DashboardAppSerializer.serialize(@dashboard_app),
      message: 'Dashboard app created successfully',
      status: :created
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message
    )
  end

  def update
    @dashboard_app.update!(permitted_payload)
    
    success_response(
      data: DashboardAppSerializer.serialize(@dashboard_app),
      message: 'Dashboard app updated successfully'
    )
  rescue ActiveRecord::RecordInvalid => e
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      e.message
    )
  end

  def destroy
    @dashboard_app.destroy!
    
    success_response(
      data: nil,
      message: 'Dashboard app deleted successfully'
    )
  rescue ActiveRecord::RecordNotDestroyed => e
    error_response(
      ApiErrorCodes::CANNOT_DELETE_RESOURCE,
      e.message
    )
  end

  private

  def fetch_dashboard_apps
    @dashboard_apps = DashboardApp.all
  end

  def fetch_dashboard_app
    @dashboard_app = @dashboard_apps.find(permitted_params[:id])
  end

  def permitted_payload
    params.require(:dashboard_app).permit(
      :title,
      :display_type,
      :sidebar_menu,
      :sidebar_position,
      content: [:url, :type]
    )
  end

  def permitted_params
    params.permit(:id)
  end
end
