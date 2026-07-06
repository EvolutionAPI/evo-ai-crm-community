# Builds absolute URLs into the SPA served by the separate evo-frontend service.
#
# The backend runs API-only by default (EVOLUTION_API_ONLY_SERVER=true), so the
# in-app `app_*` dashboard route helpers are not registered — channel OAuth
# callbacks that used them raised NoMethodError (HTTP 500). Callbacks must build
# the frontend URL explicitly and redirect the browser to the frontend host.
module FrontendRedirectable
  extend ActiveSupport::Concern

  private

  def frontend_app_url(path, **query)
    base = ENV.fetch('FRONTEND_URL', 'http://localhost:3000').chomp('/')
    url = "#{base}#{path}"
    params = query.compact
    url = "#{url}?#{params.to_query}" if params.present?
    url
  end

  # allow_other_host is required because FRONTEND_URL is a different host than the
  # backend that receives the provider callback; with load_defaults 7.0,
  # raise_on_open_redirects is on and a cross-host redirect would otherwise raise.
  def redirect_to_frontend(path, **query)
    redirect_to frontend_app_url(path, **query), allow_other_host: true
  end
end
