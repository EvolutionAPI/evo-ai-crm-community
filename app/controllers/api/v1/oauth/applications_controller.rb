class Api::V1::Oauth::ApplicationsController < Api::V1::BaseController
  require_permissions({
    index: 'oauth_applications.read',
    show: 'oauth_applications.read',
    create: 'oauth_applications.create',
    update: 'oauth_applications.update',
    destroy: 'oauth_applications.delete'
  })
  
  before_action :set_application, only: [:show, :update, :destroy, :regenerate_secret]

  def index
    apps = OauthApplication.all.order(:created_at).map { |app| application_serializer(app) }
    success_response(
      data: apps,
      meta: {
        pagination: {
          page: 1,
          page_size: apps.length,
          total: apps.length,
          total_pages: 1
        }
      }
    )
  end

  def show
    render json: application_serializer(@application)
  end

  def create
    @application = OauthApplication.all.build(application_params)

    if @application.save
      render json: application_serializer(@application), status: :created
    else
      render json: { errors: @application.errors }, status: :unprocessable_entity
    end
  end

  def update
    if @application.update(application_params)
      render json: application_serializer(@application)
    else
      render json: { errors: @application.errors }, status: :unprocessable_entity
    end
  end

  def destroy
    @application.destroy!
    head :no_content
  end

  def regenerate_secret
    @application.secret = Doorkeeper::OAuth::Helpers::UniqueToken.generate
    @application.save!
    render json: application_serializer(@application)
  end

  private

  def set_application
    @application = OauthApplication.all.find_by!(uid: params[:id])
  end

  def application_params
    params.require(:application).permit(:name, :redirect_uri, :scopes, :trusted)
  end

  def application_serializer(application)
    {
      id: application.id,
      name: application.name,
      uid: application.uid,
      secret: application.secret,
      redirect_uri: application.redirect_uri,
      scopes: application.scopes,
      trusted: application.trusted,
      created_at: application.created_at,
      updated_at: application.updated_at,
      # Informações úteis para o frontend
      token_count: application.access_tokens.count,
      last_used_at: application.access_tokens.maximum(:created_at)
    }
  end

end
