module Api
  module V1
    module Admin
      class BaseController < Api::BaseController
        before_action :authorize_admin!

        private

        # The Pundit error is rescued here, not left to the rescue_from in
        # Api::BaseController: ApplicationController wraps every action in
        # `around_action :handle_with_exception`, which catches it first and
        # answers 401/UNAUTHORIZED — a code the SPA interceptor treats as a dead
        # session and logs the user out. A permission denial must be 403.
        def authorize_admin!
          authorize :installation_config, :manage?
        rescue Pundit::NotAuthorizedError => e
          handle_not_authorized(e)
        end

        def handle_not_authorized(_exception)
          error_response(
            ApiErrorCodes::FORBIDDEN,
            'You are not authorized to perform this action',
            details: { action: 'manage', resource: 'installation_config' },
            status: :forbidden
          )
        end
      end
    end
  end
end
