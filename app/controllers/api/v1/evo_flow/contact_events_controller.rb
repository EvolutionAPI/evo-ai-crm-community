class Api::V1::EvoFlow::ContactEventsController < Api::V1::BaseController
  # Single source of truth for outbound filters. The whitelist is derived from
  # SNAKE_TO_CAMEL.keys below so the two can never drift apart -- adding a key
  # here automatically adds it to params.permit and to the camelCase output.
  SNAKE_TO_CAMEL = {
    event_type: :eventType,
    event_name: :eventName,
    channel: :channel,
    campaign_id: :campaignId,
    occurred_after: :occurredAfter,
    occurred_before: :occurredBefore,
    cursor: :cursor,
    limit: :limit
  }.freeze

  CHANNEL_LABELS = {
    'api' => 'API',
    'email' => 'Email',
    'facebook_page' => 'Facebook',
    'facebook' => 'Facebook',
    'instagram' => 'Instagram',
    'line' => 'LINE',
    'sms' => 'SMS',
    'telegram' => 'Telegram',
    'twilio_sms' => 'Twilio SMS',
    'twitter_profile' => 'Twitter',
    'twitter' => 'Twitter',
    'web_widget' => 'Website',
    'whatsapp' => 'WhatsApp'
  }.freeze

  # NOTE: Action stays user-agnostic — Service Token auth path leaves
  # Current.user nil. If user-scoped authorization is added, also require
  # Bearer / API Access Token.
  def index
    body = client.get("/contacts/#{params[:contact_id]}/events", translated_filters)
    # evo-flow wraps successful responses as `{ success, data: { events,
    # pagination }, meta }` (global ResponseTransformInterceptor). Enrich the
    # events wherever they actually live — under `data` when enveloped, or at
    # the top level for a bare `{ events: [...] }` shape (older/stubbed).
    container = body.is_a?(Hash) && body['data'].is_a?(Hash) ? body['data'] : body
    container['events'] = (container['events'] || []).map { |evt| enrich_event(evt) }
    render json: body, status: :ok
  rescue EvoFlow::HTTPError => e
    handle_evo_flow_error(e)
  end

  private

  def client
    @client ||= EvoFlow::Client.new
  end

  def translated_filters
    params.permit(*SNAKE_TO_CAMEL.keys).to_h.symbolize_keys.each_with_object({}) do |(k, v), acc|
      next if v.blank?

      acc[SNAKE_TO_CAMEL.fetch(k)] = v
    end
  end

  # `enriched` is dropped from the event when no property resolves to a value
  # (campaign/agent not found in Postgres or no enrichable key in properties),
  # keeping the response payload tight.
  def enrich_event(evt)
    props = evt['properties'] || {}
    enriched = {
      campaign_name: (enrich_campaign(props['campaign_id']) if props['campaign_id'].present?),
      channel_label: (enrich_channel(props['channel']) if props['channel'].present?),
      agent_name: (enrich_agent(props['agent_id']) if props['agent_id'].present?)
    }.compact
    enriched.empty? ? evt : evt.merge('enriched' => enriched)
  end

  # skip_nil: prevents poisoning the cache with nil when the upstream id
  # is unknown to the CRM (e.g., a campaign created moments earlier).
  def enrich_campaign(id)
    Rails.cache.fetch("evo_flow:enrich:campaign:#{id}", expires_in: 60.seconds, skip_nil: true) do
      Campaign.find_by(id: id)&.name
    end
  end

  # No cache: CHANNEL_LABELS is a frozen constant; an in-memory hash
  # lookup is cheaper than a Rails.cache round-trip.
  def enrich_channel(key)
    CHANNEL_LABELS[key.to_s] || key.to_s
  end

  def enrich_agent(id)
    Rails.cache.fetch("evo_flow:enrich:agent:#{id}", expires_in: 60.seconds, skip_nil: true) do
      User.find_by(id: id)&.name
    end
  end

  # 5xx and network failures are already logged as :error by EvoFlow::Client
  # (raise_api_error). Only emit a controller-level warn for network failures
  # (code.nil?), which the Client doesn't log on its own.
  def handle_evo_flow_error(error)
    if error.code.nil? || (500..599).cover?(error.code)
      Rails.logger.warn("[EvoFlow][ContactEvents] degraded -- code=#{error.code.inspect} msg=#{error.message}") if error.code.nil?
      render json: { events: [], degraded: true }, status: :ok
    else
      render json: safe_parse(error.response) || { error: 'upstream error' }, status: error.code
    end
  end

  def safe_parse(body)
    body = body.body if body.respond_to?(:body)
    return body if body.is_a?(Hash)

    JSON.parse(body)
  rescue StandardError
    nil
  end
end
