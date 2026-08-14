class Api::BaseController < ApplicationController
  include AccessTokenAuthHelper
  include EvoAuthConcern
  include ServiceTokenAuthConcern
  include EvoPermissionConcern
  include ApiResponseHelper

  before_action :authenticate_request!

  # Global exception handlers for standardized error responses
  # Keep StandardError declared first so specific handlers below take precedence.
  rescue_from StandardError, with: :handle_internal_error
  rescue_from ActiveRecord::RecordNotFound, with: :handle_record_not_found
  rescue_from ActiveRecord::RecordInvalid, with: :handle_record_invalid
  rescue_from ActiveRecord::RecordNotUnique, with: :handle_record_not_unique
  rescue_from Pundit::NotAuthorizedError, with: :handle_not_authorized
  rescue_from ActionController::ParameterMissing, with: :handle_parameter_missing

  private

  def authenticate_request!
    # Request-scoped caches to avoid duplicate remote calls during a single request lifecycle.
    Current.evo_auth_validation_cache ||= {}
    Current.evo_permission_cache ||= {}

    # Priority order: Service Token -> Bearer Token -> API Access Token
    if service_token_present?
      authenticate_service_token!
    elsif bearer_token_present?
      # Extract Bearer token and pass to EvoAuth
      bearer_token = request.headers['Authorization']&.sub(/^Bearer /, '')
      authenticate_user_with_evo_auth(bearer_token, 'bearer')
    elsif api_access_token_present?
      # Extract api_access_token and pass to EvoAuth
      # Check multiple header formats: Rails converts headers with underscores to HTTP_ prefix
      # When nginx receives api_access_token, it becomes HTTP_API_ACCESS_TOKEN in Rails
      api_token = request.headers['HTTP_API_ACCESS_TOKEN'] ||
                  request.headers[:HTTP_API_ACCESS_TOKEN] ||
                  request.headers['api_access_token'] ||
                  request.headers[:api_access_token] ||
                  request.headers['Api-Access-Token'] ||
                  request.headers['X-Api-Access-Token']
      authenticate_user_with_evo_auth(api_token, 'api_access_token')
      validate_bot_access_token! unless performed?
    else
      render_unauthorized('Authentication required')
    end
  end

  def bearer_token_present?
    request.headers['Authorization']&.start_with?('Bearer ')
  end

  def api_access_token_present?
    # Check multiple header formats: Rails converts headers with underscores to HTTP_ prefix
    # When nginx receives api_access_token, it becomes HTTP_API_ACCESS_TOKEN in Rails
    # Priority: HTTP_API_ACCESS_TOKEN (from nginx) > api_access_token (direct) > other formats
    request.headers['HTTP_API_ACCESS_TOKEN'].present? ||
              request.headers[:HTTP_API_ACCESS_TOKEN].present? ||
              request.headers['api_access_token'].present? ||
              request.headers[:api_access_token].present? ||
              request.headers['Api-Access-Token'].present? ||
              request.headers['X-Api-Access-Token'].present?
  end

  def access_token_present?
    api_access_token_present?
  end

  def check_admin_authorization?
    raise Pundit::NotAuthorizedError unless Current.user&.role == 'administrator'
  end

  def apply_pagination
    # Padrão: page e pageSize (camelCase) conforme API_RESPONSE_STANDARD.md
    # Aceita pageSize (padrão) ou page_size/per_page (compatibilidade)
    page = params[:page]&.to_i || 1
    page_size = params[:pageSize]&.to_i || params[:page_size]&.to_i || params[:per_page]&.to_i || 20
    page_size = [page_size.to_i, 1].max

    paginate_instance_variables(page, page_size)
  end

  # Every rescue_from below turns an exception into a response body, which is the
  # only place it would otherwise be visible. When the action already rendered —
  # a callback raising after the response was sent — there is no body left to put
  # it in, so without this the exception disappears entirely. handle_internal_error
  # has always logged; the specific handlers now do the same.
  def log_rescued_exception(exception)
    Rails.logger.error("[api] #{exception.class}: #{exception.message}")
    Rails.logger.error(exception.backtrace.first(5).join("\n")) if exception.backtrace
  end

  # Handle ActiveRecord::RecordNotFound
  def handle_record_not_found(exception)
    log_rescued_exception(exception)
    resource_name = exception.model.to_s.underscore.upcase
    error_code = "#{resource_name}_NOT_FOUND"

    # Use predefined error code if exists, fallback to dynamic
    error_code = ApiErrorCodes.const_get(error_code) if ApiErrorCodes.const_defined?(error_code)

    error_response(
      error_code,
      "#{exception.model} not found",
      details: { id: exception.id, model: exception.model },
      status: :not_found
    )
  end

  # Handle ActiveRecord::RecordInvalid (validation errors)
  def handle_record_invalid(exception)
    log_rescued_exception(exception)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      'Validation failed',
      details: format_validation_errors(exception.record.errors),
      status: :unprocessable_entity
    )
  end

  # Handle ActiveRecord::RecordNotUnique (duplicate entries)
  def handle_record_not_unique(exception)
    log_rescued_exception(exception)
    error_response(
      ApiErrorCodes::RESOURCE_ALREADY_EXISTS,
      'Resource already exists',
      details: { message: exception.message },
      status: :conflict
    )
  end

  # Handle Pundit::NotAuthorizedError (authorization failures)
  def handle_not_authorized(exception)
    log_rescued_exception(exception)
    error_response(
      ApiErrorCodes::FORBIDDEN,
      'You are not authorized to perform this action',
      details: {
        action: exception.query,
        record: exception.record.class.name
      },
      status: :forbidden
    )
  end

  # Handle ActionController::ParameterMissing
  def handle_parameter_missing(exception)
    log_rescued_exception(exception)
    error_response(
      ApiErrorCodes::MISSING_REQUIRED_FIELD,
      "Required parameter missing: #{exception.param}",
      details: { parameter: exception.param },
      status: :bad_request
    )
  end

  # Handle generic StandardError (catch-all for unexpected errors)
  def handle_internal_error(exception)
    # Log the full error for debugging
    Rails.logger.error "Internal Server Error: #{exception.class} - #{exception.message}"
    Rails.logger.error exception.backtrace.join("\n")

    return if performed?

    # In production, don't expose internal error details
    if Rails.env.production?
      error_response(
        ApiErrorCodes::INTERNAL_ERROR,
        'An unexpected error occurred',
        status: :internal_server_error
      )
    else
      # In development, include more details for debugging
      error_response(
        ApiErrorCodes::INTERNAL_ERROR,
        exception.message,
        details: {
          exception_class: exception.class.name,
          backtrace: exception.backtrace.first(5)
        },
        status: :internal_server_error
      )
    end
  end

  # Format validation errors into structured array
  def format_validation_errors(errors)
    errors.messages.map do |field, messages|
      {
        field: field,
        messages: messages,
        full_messages: errors.full_messages_for(field)
      }
    end
  end
end
