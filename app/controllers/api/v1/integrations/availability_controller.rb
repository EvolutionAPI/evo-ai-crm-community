# frozen_string_literal: true

# Reports, per integration provider, whether its OAuth credential is configured.
#
# Returns BOOLEANS only — never the secret itself — so the frontend can decide
# which integration tiles to enable without exposing any client id/secret.
#
# Session-authed on purpose: it inherits Api::BaseController's authenticate_request!
# (no skip_before_action). If it were public it would become a config probe.
# Reads exclusively through GlobalConfigService.load, so it works standalone
# (reports the global OAuth config) and stays correct when that service is
# decorated to scope config per caller — this controller itself needs no
# awareness of how the value is resolved; the request context already scopes it.
class Api::V1::Integrations::AvailabilityController < Api::BaseController
  def index
    render json: { data: availability }
  end

  private

  def availability
    {
      # ABA Integrações (client_id + secret)
      google_calendar: configured?('GOOGLE_CALENDAR_CLIENT_ID', 'GOOGLE_CALENDAR_CLIENT_SECRET'),
      google_sheets: configured?('GOOGLE_SHEETS_CLIENT_ID', 'GOOGLE_SHEETS_CLIENT_SECRET'),

      # ABA MCP (client_id + secret)
      github: configured?('GITHUB_OAUTH_CLIENT_ID', 'GITHUB_OAUTH_CLIENT_SECRET'),
      notion: configured?('NOTION_OAUTH_CLIENT_ID', 'NOTION_OAUTH_CLIENT_SECRET'),
      hubspot: configured?('HUBSPOT_OAUTH_CLIENT_ID', 'HUBSPOT_OAUTH_CLIENT_SECRET'),
      linear: configured?('LINEAR_CLIENT_ID', 'LINEAR_CLIENT_SECRET'),
      monday: configured?('MONDAY_OAUTH_CLIENT_ID', 'MONDAY_OAUTH_CLIENT_SECRET'),
      atlassian: configured?('ATLASSIAN_OAUTH_CLIENT_ID', 'ATLASSIAN_OAUTH_CLIENT_SECRET'),
      asana: configured?('ASANA_OAUTH_CLIENT_ID', 'ASANA_OAUTH_CLIENT_SECRET'),
      paypal: configured?('PAYPAL_OAUTH_CLIENT_ID', 'PAYPAL_OAUTH_CLIENT_SECRET'),
      canva: configured?('CANVA_OAUTH_CLIENT_ID', 'CANVA_OAUTH_CLIENT_SECRET'),

      # ABA MCP (dynamic registration → available when the redirect_uri is present;
      # client id/secret are obtained at runtime via OAuth dynamic registration)
      supabase: redirect_configured?('SUPABASE_OAUTH_REDIRECT_URI'),
      stripe: redirect_configured?('STRIPE_OAUTH_REDIRECT_URI'),
    }
  end

  # A provider is available when BOTH its client id and secret are populated.
  # Mirrors GlobalConfigController#openai_configured? — load with a blank default,
  # coerce to string, strip, then check presence. Never returns the value itself.
  def configured?(id_key, secret_key)
    GlobalConfigService.load(id_key, '').to_s.strip.present? &&
      GlobalConfigService.load(secret_key, '').to_s.strip.present?
  end

  # Dynamic-registration providers (supabase/stripe) only carry a redirect_uri in
  # global config; the client id/secret come from OAuth dynamic registration. So
  # "available" here means the redirect_uri is configured.
  def redirect_configured?(uri_key)
    GlobalConfigService.load(uri_key, '').to_s.strip.present?
  end
end
