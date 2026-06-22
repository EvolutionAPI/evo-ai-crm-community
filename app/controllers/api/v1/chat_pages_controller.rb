# frozen_string_literal: true

# Admin CRUD for public chat pages (B14.08). Authenticated + permission-gated
# via the evo-auth-service catalog (chat_pages.{read,create,update,delete}).
#
# A ChatPage wraps an existing Channel::WebWidget (by website_token); this
# controller manages the page metadata only — it does not create widgets.
class Api::V1::ChatPagesController < Api::V1::BaseController
  require_permissions({
                        index: 'chat_pages.read',
                        show: 'chat_pages.read',
                        create: 'chat_pages.create',
                        update: 'chat_pages.update',
                        destroy: 'chat_pages.delete'
                      })

  before_action :fetch_chat_page, only: [:show, :update, :destroy]

  def index
    scope = ChatPage.order(created_at: :desc)

    if params[:search].present?
      q = "%#{params[:search].strip}%"
      scope = scope.where('chat_pages.title ILIKE :q OR chat_pages.slug ILIKE :q OR chat_pages.description ILIKE :q', q: q)
    end

    scope = scope.where(published: ActiveModel::Type::Boolean.new.cast(params[:published])) if params[:published].present?

    page = params[:page].presence || 1
    per_page = params[:pageSize].presence || params[:per_page].presence || 20
    @chat_pages = scope.page(page).per(per_page)

    paginated_response(
      data: @chat_pages.map { |chat_page| ChatPageSerializer.serialize(chat_page) },
      collection: @chat_pages,
      message: 'Chat pages retrieved successfully'
    )
  end

  def show
    success_response(
      data: ChatPageSerializer.serialize(@chat_page),
      message: 'Chat page retrieved successfully'
    )
  end

  def create
    @chat_page = ChatPage.new(chat_page_params)

    if @chat_page.save
      success_response(
        data: ChatPageSerializer.serialize(@chat_page),
        message: 'Chat page created successfully',
        status: :created
      )
    else
      validation_error(@chat_page)
    end
  end

  def update
    if @chat_page.update(chat_page_params)
      success_response(
        data: ChatPageSerializer.serialize(@chat_page),
        message: 'Chat page updated successfully'
      )
    else
      validation_error(@chat_page)
    end
  end

  def destroy
    @chat_page.destroy
    success_response(
      data: { id: @chat_page.id },
      message: 'Chat page deleted successfully'
    )
  end

  private

  def fetch_chat_page
    @chat_page = ChatPage.find(params[:id])
  end

  def chat_page_params
    params.require(:chat_page).permit(
      :slug, :title, :description, :published, :website_token,
      appearance: {}
    )
  end

  def validation_error(record)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Validation failed',
      details: record.errors.full_messages,
      status: :unprocessable_entity
    )
  end
end
