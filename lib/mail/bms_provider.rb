require 'net/http'
require 'json'

module Mail
  class BmsProvider
    class DeliveryError < StandardError; end

    def initialize(_settings); end

        def deliver!(mail)
      Rails.logger.info "🚀 BMS PROVIDER: Starting email delivery"
      Rails.logger.info "🚀 BMS PROVIDER: Mail From: #{mail.header[:from]}"
      Rails.logger.info "🚀 BMS PROVIDER: Mail To: #{mail.header[:to]}"
      Rails.logger.info "🚀 BMS PROVIDER: Mail Subject: #{mail.header[:subject]}"

      # Extract email details from mail object
      from_email = extract_email_from_header(mail.header[:from].to_s)
      from_name = extract_name_from_header(mail.header[:from].to_s)
      to_email = extract_email_from_header(mail.header[:to].to_s)
      to_name = extract_name_from_header(mail.header[:to].to_s) || to_email.split('@')[0]

      Rails.logger.info "🚀 BMS PROVIDER: Extracted - From: #{from_name} <#{from_email}>, To: #{to_name} <#{to_email}>"

      # Build BMS API payload
      message_id = generate_message_id
      Rails.logger.info "🚀 BMS PROVIDER: Generated message ID: #{message_id} (#{message_id.class})"

      payload = {
        contact: {
          email: to_email,
          firstName: to_name
        },
        message: {
          id: message_id,
          title: mail.header[:subject].to_s,
          from: {
            email: from_email,
            firstName: from_name || from_email.split('@')[0]
          },
          ippool: GlobalConfigService.load('BMS_IPPOOL', 'default'),
          subject: mail.header[:subject].to_s,
          content: mail.decoded
        }
      }

      Rails.logger.info "🚀 BMS PROVIDER: Payload prepared for API call"
      bms_api_key = GlobalConfigService.load('BMS_API_SECRET', nil)
      bms_ippool = GlobalConfigService.load('BMS_IPPOOL', 'default')

      Rails.logger.info "🚀 BMS PROVIDER: API Key: #{bms_api_key.present? ? '***CONFIGURED***' : '***NOT SET***'}"
      Rails.logger.info "🚀 BMS PROVIDER: IP Pool: #{bms_ippool}"

      # Validate API key before making request
      raise DeliveryError, "BMS_API_SECRET not configured" if bms_api_key.blank?

      response = send_via_bms_api(payload)
      Rails.logger.info "✅ BMS PROVIDER: Email sent successfully via BMS API!"
      Rails.logger.info "✅ BMS PROVIDER: Response: #{response}"

      response
    rescue StandardError => e
      Rails.logger.error "❌ BMS PROVIDER: Failed to send email via BMS: #{e.message}"
      Rails.logger.error "❌ BMS PROVIDER: Error class: #{e.class}"
      Rails.logger.error "❌ BMS PROVIDER: Backtrace: #{e.backtrace&.first(3)&.join(', ')}"
      raise DeliveryError, "Failed to send email via BMS: #{e.message}"
    end

    private

    # Base host of the BMS API. BMS_API_URL points each installation at its own
    # instance; the legacy host only remains as the fallback for an empty config.
    # The API has no /api global prefix (that segment only exists through the
    # front's nginx rewrite), so a configured base carrying it is normalized,
    # otherwise POST /api/services/send-email answers 404.
    LEGACY_API_BASE = 'https://bms-api.bri.us'.freeze

    def bms_api_base
      configured = GlobalConfigService.load('BMS_API_URL', nil).to_s.strip
      base = configured.empty? ? LEGACY_API_BASE : configured
      base.sub(%r{/+\z}, '').delete_suffix('/api')
    end

    def send_via_bms_api(payload)
      uri = URI("#{bms_api_base}/services/send-email")
      Rails.logger.info "🌐 BMS API: Calling #{uri}"
      Rails.logger.info "🌐 BMS API: Payload size: #{payload.to_json.length} bytes"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 30
      http.open_timeout = 10

      request = Net::HTTP::Post.new(uri)
      bms_api_key = GlobalConfigService.load('BMS_API_SECRET', nil)
      raise DeliveryError, "BMS_API_SECRET not configured" if bms_api_key.blank?

      request['api-key'] = bms_api_key
      request['Content-Type'] = 'application/json'
      request.body = payload.to_json

      Rails.logger.info "🌐 BMS API: Request headers set, making HTTP call..."

      start_time = Time.current
      response = http.request(request)
      duration = ((Time.current - start_time) * 1000).round(2)

      Rails.logger.info "🌐 BMS API: Response received in #{duration}ms"
      Rails.logger.info "🌐 BMS API: Status Code: #{response.code}"
      Rails.logger.info "🌐 BMS API: Response Body: #{response.body}"

      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error "❌ BMS API: Error response - Code: #{response.code}, Body: #{response.body}"
        raise DeliveryError, "BMS API returned error: #{response.code} - #{response.body}"
      end

      parsed_response = JSON.parse(response.body)
      Rails.logger.info "✅ BMS API: Successfully parsed response: #{parsed_response}"
      parsed_response
    rescue JSON::ParserError => e
      Rails.logger.error "❌ BMS API: Failed to parse JSON response: #{e.message}"
      Rails.logger.error "❌ BMS API: Raw response body: #{response&.body}"
      raise DeliveryError, "BMS API returned invalid JSON: #{e.message}"
    rescue Timeout::Error => e
      Rails.logger.error "❌ BMS API: Request timeout: #{e.message}"
      raise DeliveryError, "BMS API request timeout: #{e.message}"
    rescue StandardError => e
      Rails.logger.error "❌ BMS API: Unexpected error: #{e.class} - #{e.message}"
      raise
    end

    def extract_email_from_header(header_value)
      # Extract email from "Name <email@domain.com>" or just "email@domain.com"
      match = header_value.match(/<(.+)>/) || header_value.match(/(\S+@\S+)/)
      match ? match[1] : header_value.strip
    end

    def extract_name_from_header(header_value)
      # Extract name from "Name <email@domain.com>"
      match = header_value.match(/^([^<]+)</)
      match ? match[1].strip : nil
    end

    def generate_message_id
      # BMS API expects a number, so we'll use timestamp + random number
      timestamp = Time.now.to_i
      random_suffix = rand(10000..99999)
      (timestamp.to_s + random_suffix.to_s).to_i
    end
  end
end
