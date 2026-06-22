require 'digest'

class Rack::Attack
  ### Configure Cache ###

  # If you don't want to use Rails.cache (Rack::Attack's default), then
  # configure it here.
  #
  # Note: The store is only used for throttling (not blocklisting and
  # safelisting). It must implement .increment and .write like
  # ActiveSupport::Cache::Store

  # Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

  # https://github.com/rack/rack-attack/issues/102
  # Rails 7.1 automatically adds its own ConnectionPool around RedisCacheStore.
  # Because `$velma` is *already* a ConnectionPool, double-wrapping causes
  # Redis calls like `get` to hit the outer wrapper and explode.
  # `pool: false` tells Rails to skip its internal pool and use ours directly.
  # TODO: We can use build in connection pool in future upgrade
  Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(redis: $velma, pool: false)

  class Request < ::Rack::Request
    # You many need to specify a method to fetch the correct remote IP address
    # if the web server is behind a load balancer.
    def remote_ip
      @remote_ip ||= (env['action_dispatch.remote_ip'] || ip).to_s
    end

    def allowed_ip?
      default_allowed_ips = ['127.0.0.1', '::1']
      env_allowed_ips = ENV.fetch('RACK_ATTACK_ALLOWED_IPS', '').split(',').map(&:strip)
      (default_allowed_ips + env_allowed_ips).include?(remote_ip)
    end

    # Rails would allow requests to paths with extentions, so lets compare against the path with extention stripped
    # example /auth & /auth.json would both work
    def path_without_extentions
      path[/^[^.]+/]
    end
  end

  ### Safelist IPs from Environment Variable ###
  #
  # This block ensures requests from any IP present in RACK_ATTACK_ALLOWED_IPS
  # will bypass Rack::Attack’s throttling rules.
  #
  # Example: RACK_ATTACK_ALLOWED_IPS="127.0.0.1,::1,192.168.0.10"

  Rack::Attack.safelist('trusted IPs', &:allowed_ip?)

  ### Throttle Spammy Clients ###

  # If any single client IP is making tons of requests, then they're
  # probably malicious or a poorly-configured scraper. Either way, they
  # don't deserve to hog all of the app server's CPU. Cut them off!
  #
  # Note: If you're serving assets through rack, those requests may be
  # counted by rack-attack and this throttle may be activated too
  # quickly. If so, enable the condition to exclude them from tracking.

  # Throttle all requests by IP (60rpm)
  #
  # Key: "rack::attack:#{Time.now.to_i/:period}:req/ip:#{req.ip}"

  throttle('req/ip', limit: ENV.fetch('RACK_ATTACK_LIMIT', '3000').to_i, period: 1.minute, &:ip)

  ###-----------------------------------------------###
  ###-----Authentication Related Throttling---------###
  ###-----------------------------------------------###

  ### Prevent Brute-Force Login Attacks ###
  throttle('login/ip', limit: 5, period: 5.minutes) do |req|
    req.ip if req.path_without_extentions == '/auth/sign_in' && req.post?
  end

  throttle('login/email', limit: 10, period: 15.minutes) do |req|
    if req.path_without_extentions == '/auth/sign_in' && req.post?
      # ref: https://github.com/rack/rack-attack/issues/399
      # NOTE: This line used to throw ArgumentError /rails/action_mailbox/sendgrid/inbound_emails : invalid byte sequence in UTF-8
      # Hence placed in the if block
      email = req.params['email'].presence || ActionDispatch::Request.new(req.env).params['email'].presence
      email.to_s.downcase.gsub(/\s+/, '')
    end
  end

  ## Reset password throttling
  throttle('reset_password/ip', limit: 5, period: 30.minutes) do |req|
    req.ip if req.path_without_extentions == '/auth/password' && req.post?
  end

  throttle('reset_password/email', limit: 5, period: 1.hour) do |req|
    if req.path_without_extentions == '/auth/password' && req.post?
      email = req.params['email'].presence || ActionDispatch::Request.new(req.env).params['email'].presence
      email.to_s.downcase.gsub(/\s+/, '')
    end
  end

  ## Resend confirmation throttling
  throttle('resend_confirmation/ip', limit: 5, period: 30.minutes) do |req|
    req.ip if req.path_without_extentions == '/api/v1/profile/resend_confirmation' && req.post?
  end

  ## Prevent Brute-Force Signup Attacks ###
  throttle('accounts/ip', limit: 5, period: 30.minutes) do |req|
    req.ip if req.path_without_extentions == '/api/v1/accounts' && req.post?
  end

  ## Anti-spam for anonymous lead-capture form submissions (B14.01) ###
  throttle('public/forms/submissions/ip', limit: ENV.fetch('FORM_SUBMISSION_RATE_LIMIT', '10').to_i, period: 1.hour) do |req|
    req.ip if req.post? && req.path_without_extentions.match?(%r{\A/public/api/v1/forms/[^/]+/submissions\z})
  end

  ##-----------------------------------------------##

  ###-----------------------------------------------###
  ###-----------Widget API Throttling---------------###
  ###-----------------------------------------------###

  # Rack attack on widget APIs can be disabled by setting ENABLE_RACK_ATTACK_WIDGET_API to false
  # For clients using the widgets in specific conditions like inside and iframe
  # TODO: Deprecate this feature in future after finding a better solution
  if ActiveModel::Type::Boolean.new.cast(ENV.fetch('ENABLE_RACK_ATTACK_WIDGET_API', true))
    ## Prevent Conversation Bombing on Widget APIs ###
    # Rate limit: Create conversation
    throttle('widget/conversations/create/ip', limit: ENV.fetch('WIDGET_RATE_LIMIT_CREATE_CONVERSATION', '10').to_i, period: 1.minute) do |req|
      req.ip if req.path_without_extentions == '/api/v1/widget/conversations' && req.post?
    end

    ## Prevent Message Spam
    throttle('widget/messages/create/conversation', limit: ENV.fetch('WIDGET_RATE_LIMIT_SEND_MESSAGE', '30').to_i, period: 1.minute) do |req|
      if req.path_without_extentions == '/api/v1/widget/messages' && req.post?
        # Extract conversation_id from params
        request_params = ActionDispatch::Request.new(req.env).params
        conversation_id = request_params.dig('message', 'conversation_id') || request_params['conversation_id']
        # Use conversation_id if present, otherwise fallback to IP
        conversation_id.presence || req.ip
      end
    end

    ## Prevent File Upload Abuse
    throttle('widget/direct_uploads/create/conversation', limit: ENV.fetch('WIDGET_RATE_LIMIT_UPLOAD_FILE', '5').to_i, period: 1.minute) do |req|
      if req.path_without_extentions == '/api/v1/widget/direct_uploads' && req.post?
        # Extract conversation_id from params if available
        request_params = ActionDispatch::Request.new(req.env).params
        conversation_id = request_params['conversation_id'] || request_params.dig('blob', 'metadata', 'conversation_id')
        # Use conversation_id if present, otherwise use IP + website_token as fallback
        if conversation_id.present?
          conversation_id
        else
          website_token = request_params['website_token'] || req.get_header('HTTP_X_WEBSITE_TOKEN')
          "#{req.ip}:#{website_token}" if website_token.present?
        end
      end
    end

    ## Prevent Contact update Bombing in Widget API ###
    throttle('api/v1/widget/contacts', limit: 60, period: 1.hour) do |req|
      req.ip if req.path_without_extentions == '/api/v1/widget/contacts' && (req.patch? || req.put?)
    end

    ## Prevent Conversation Bombing through multiple sessions
    throttle('widget?website_token={website_token}&evo_conversation={x-auth-token}', limit: 5, period: 1.hour) do |req|
      req.ip if req.path_without_extentions == '/widget' && ActionDispatch::Request.new(req.env).params['evo_conversation'].blank?
    end
  end

  ##-----------------------------------------------##

  ###-----------------------------------------------###
  ###----------Application API Throttling-----------###
  ###-----------------------------------------------###

  ## Prevent Abuse of Conversation Transcript APIs ###
  throttle('/api/v1/conversations/:conversation_id/transcript', limit: 30, period: 1.hour) do |req|
    match_data = %r{/api/v1/conversations/(?<conversation_id>\d+)/transcript}.match(req.path)
    req.ip if match_data.present?
  end

  ## Prevent Abuse of attachment upload APIs ##
  throttle('/api/v1/upload', limit: 60, period: 1.hour) do |req|
    req.ip if req.path_without_extentions&.end_with?('/upload')
  end

  ## Prevent abuse of contact search api
  throttle('/api/v1/contacts/search', limit: ENV.fetch('RATE_LIMIT_CONTACT_SEARCH', '100').to_i, period: 1.minute) do |req|
    req.ip if req.path_without_extentions&.end_with?('/contacts/search')
  end

  # Throttle by individual user (based on uid)
  throttle('/api/v2/reports/user', limit: ENV.fetch('RATE_LIMIT_REPORTS_API_USER_LEVEL', '100').to_i, period: 1.minute) do |req|
    match_data = %r{/api/v2/reports}.match(req.path)
    # Extract user identification (uid for web, api_access_token for API requests)
    user_uid = req.get_header('HTTP_UID')
    api_access_token = req.get_header('HTTP_API_ACCESS_TOKEN') || req.get_header('api_access_token')

    # Use uid if present, otherwise fallback to api_access_token for tracking
    user_identifier = user_uid.presence || api_access_token.presence

    user_identifier if match_data.present? && user_identifier.present?
  end

  ## Prevent abuse of reports api
  throttle('/api/v2/reports', limit: ENV.fetch('RATE_LIMIT_REPORTS_API_ACCOUNT_LEVEL', '1000').to_i, period: 1.minute) do |req|
    match_data = %r{/api/v2/reports}.match(req.path)
    req.ip if match_data.present?
  end

  ## Prevent abuse of products bulk import (EVO-1555 S1)
  ## Each request can ingest up to 500 products; default 10 reqs/min/key = 5000 products/min/key.
  ## Endpoint authenticates via Authorization: Bearer; discriminator hashes the token (digest, not raw)
  ## so the Redis key never holds credentials. Falls back to api_access_token then IP.
  throttle('api/v1/products/bulk', limit: ENV.fetch('RATE_LIMIT_PRODUCTS_BULK', '10').to_i, period: 1.minute) do |req|
    if req.path_without_extentions == '/api/v1/products/bulk' && req.post?
      authorization = req.get_header('HTTP_AUTHORIZATION')
      api_token     = req.get_header('HTTP_API_ACCESS_TOKEN') || req.get_header('api_access_token')

      if authorization.present?
        "bearer:#{Digest::SHA256.hexdigest(authorization)}"
      elsif api_token.present?
        "api_token:#{Digest::SHA256.hexdigest(api_token)}"
      else
        "ip:#{req.ip}"
      end
    end
  end

  ## Prevent abuse of the ERP webhook receiver (EVO-1735 S3.0)
  ## Each request can ingest up to 500 products via Products::BulkImporter
  ## (same ceiling as /api/v1/products/bulk). The discriminator is the
  ## provider segment of the path, so the 11th request from a given
  ## provider in the window trips 429 regardless of signature/payload —
  ## which is what AC8 requires. A compromised secret still throttles.
  throttle('api/v1/webhooks/erp', limit: ENV.fetch('RATE_LIMIT_ERP_WEBHOOK', '10').to_i, period: 1.minute) do |req|
    match_data = %r{\A/api/v1/webhooks/erp/([^/]+)\z}.match(req.path_without_extentions)
    "erp_webhook:#{match_data[1]}" if match_data && req.post?
  end

  ## ----------------------------------------------- ##
end

# Log blocked events
ActiveSupport::Notifications.subscribe('throttle.rack_attack') do |_name, _start, _finish, _request_id, payload|
  req = payload[:request]

  user_uid = req.get_header('HTTP_UID')
  api_access_token = req.get_header('HTTP_API_ACCESS_TOKEN') || req.get_header('api_access_token')

  # Mask the token if present
  masked_api_token = api_access_token.present? ? "#{api_access_token[0..4]}...[REDACTED]" : nil

  # Use uid if present, otherwise fallback to masked api_access_token for tracking
  user_identifier = user_uid.presence || masked_api_token.presence || 'unknown_user'

  Rails.logger.warn(
    "[Rack::Attack][Blocked] remote_ip: \"#{req.remote_ip}\", " \
    "path: \"#{req.path}\", " \
    "user_identifier: \"#{user_identifier}\", " \
    "method: \"#{req.request_method}\", " \
    "user_agent: \"#{req.user_agent}\""
  )
end

Rack::Attack.enabled = Rails.env.production? ? ActiveModel::Type::Boolean.new.cast(ENV.fetch('ENABLE_RACK_ATTACK', true)) : false
