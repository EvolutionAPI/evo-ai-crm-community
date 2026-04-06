require 'googleauth'

module ConfigTest
  class FirebaseTestService
    TIMEOUT = 15
    REQUIRED_FIELDS = %w[project_id client_email private_key].freeze

    def call
      credentials_json = GlobalConfigService.load('FIREBASE_CREDENTIALS_SECRET', nil)
      return { success: false, message: 'Firebase credentials not configured' } if credentials_json.blank?

      credentials = JSON.parse(credentials_json)

      missing = REQUIRED_FIELDS.select { |f| credentials[f].blank? }
      return { success: false, message: "Missing required fields: #{missing.join(', ')}" } if missing.any?

      project_id = GlobalConfigService.load('FIREBASE_PROJECT_ID', nil)
      if project_id.present? && credentials['project_id'] != project_id
        return { success: false,
                 message: "Credentials project_id '#{credentials['project_id']}' doesn't match configured FIREBASE_PROJECT_ID '#{project_id}'" }
      end

      authorizer = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: StringIO.new(credentials_json),
        scope: 'https://www.googleapis.com/auth/firebase.messaging'
      )
      Timeout.timeout(TIMEOUT) { authorizer.fetch_access_token! }

      { success: true, message: 'Firebase credentials valid' }
    rescue JSON::ParserError => e
      { success: false, message: "Invalid JSON: #{e.message}" }
    rescue Signet::AuthorizationError => e
      { success: false, message: "Firebase authentication failed: #{e.message}" }
    rescue Timeout::Error
      { success: false, message: "Firebase validation timed out after #{TIMEOUT} seconds" }
    rescue StandardError => e
      { success: false, message: "Firebase validation failed: #{e.message}" }
    end
  end
end
