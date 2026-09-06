# config/initializers/cors.rb
# ref: https://github.com/cyu/rack-cors

# font cors issue with CDN
# Ref: https://stackoverflow.com/questions/56960709/rails-font-cors-policy
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  # Get CORS origins from environment variable
  cors_origins = ENV.fetch('CORS_ORIGINS', 'http://localhost:3000,http://localhost:5173,http://localhost:8080').split(',')

  # ActiveStorage blobs - allow all origins (public resources)
  allow do
    origins '*'
    resource '/rails/active_storage/*', headers: :any, methods: [:get, :options, :head]
  end

  # Custom HTML tools embedded via Editor/Site (menu_configs) render inside a
  # sandbox="allow-scripts allow-popups allow-forms" iframe — deliberately
  # missing allow-same-origin, so the browser sends Origin: null and has no
  # access to cookies/localStorage. Auth there uses a Personal Access Token
  # (api_access_token header) instead of a session; scoped to just these two
  # path prefixes (not the whole /api/*) to keep the exposure narrow.
  allow do
    # rack-cors' `origins` DSL auto-wraps any bare string into
    # /^[a-z][a-z0-9.+-]*:\/\/STRING$/ (it assumes a hostname needing a scheme
    # prefix), so origins 'null' compiled to /^...:\/\/null$/ which can never
    # match the literal `Origin: null` header browsers send for sandboxed
    # iframes with no allow-same-origin. Passing a Regexp bypasses that
    # coercion and is matched against the origin as-is.
    origins(/\Anull\z/)
    resource '/api/v1/reports/*', headers: :any, methods: :any
    resource '/api/v1/tools_proxy/*', headers: :any, methods: :any
  end

  allow do
    origins cors_origins

    # Health check endpoints
    resource '/health/*', headers: :any, methods: [:get, :options]

    # Static assets
    resource '/packs/*', headers: :any, methods: [:get, :options]
    resource '/audio/*', headers: :any, methods: [:get, :options]

    # Public API endpoints
    resource '/public/api/*', headers: :any, methods: :any

    # API endpoints in development or when explicitly enabled
    if Rails.env.development? || ActiveModel::Type::Boolean.new.cast(ENV.fetch('ENABLE_API_CORS', true))
      resource '/api/*',
               headers: :any,
               methods: :any,
               expose: %w[Authorization],
               credentials: true
    end
  end
end

################################################
######### Action Cable Related Config ##########
################################################

# Mount Action Cable outside main process or domain
# Rails.application.config.action_cable.mount_path = nil
# Rails.application.config.action_cable.url = 'wss://example.com/cable'

# Get CORS origins from environment variable for ActionCable
cors_origins = ENV.fetch('CORS_ORIGINS', 'http://localhost:3000,http://localhost:5173,http://localhost:8080').split(',')

# Configure ActionCable allowed request origins
Rails.application.config.action_cable.allowed_request_origins = cors_origins

# To Enable connecting to the API channel public APIs
# ref : https://medium.com/@emikaijuin/connecting-to-action-cable-without-rails-d39a8aaa52d5
Rails.application.config.action_cable.disable_request_forgery_protection = true
