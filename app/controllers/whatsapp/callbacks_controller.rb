class Whatsapp::CallbacksController < ApplicationController
  include FrontendRedirectable

  def show
    Rails.logger.info "WhatsApp callback controller called with params: #{params.inspect}"
    Rails.logger.info "Request URL: #{request.url}"
    Rails.logger.info "Request referer: #{request.referer}"

    # Check if WhatsApp redirected with an error (user canceled authorization)
    if params[:error].present?
      Rails.logger.error "WhatsApp callback error: #{params[:error]}"
      handle_authorization_error
      return
    end

    Rails.logger.info 'WhatsApp callback success, redirecting to setup page'
    # For WhatsApp, we just redirect to the setup page with the authorization code
    # The actual token exchange will be handled by the Vue.js frontend
    redirect_to_setup_page
  rescue StandardError => e
    handle_error(e)
  end

  private

  def redirect_to_setup_page
    redirect_to_frontend(
      '/app/settings/inboxes/new/whatsapp',
      code: params[:code],
      state: params[:state]
    )
  end

  def handle_authorization_error
    error_info = {
      'error_type' => params[:error] || 'authorization_error',
      'code' => 400,
      'error_message' => params[:error_description] || 'Authorization was denied'
    }

    Rails.logger.error("WhatsApp Authorization Error: #{error_info['error_message']}")
    redirect_to_error_page(error_info)
  end

  def handle_error(error)
    Rails.logger.error("WhatsApp Channel creation Error: #{error.message}")
    EvolutionExceptionTracker.new(error).capture_exception

    error_info = {
      'error_type' => error.class.name,
      'code' => 500,
      'error_message' => error.message
    }

    redirect_to_error_page(error_info)
  end

  def redirect_to_error_page(error_info)
    redirect_to_frontend(
      '/app/settings/inboxes/new/whatsapp',
      error_type: error_info['error_type'],
      code: error_info['code'],
      error_message: error_info['error_message']
    )
  end
end
