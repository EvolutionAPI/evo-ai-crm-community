class EvolutionGo::HealthMonitorService
  def initialize(monitor)
    @monitor = monitor
  end

  def perform
    health = fetch_health
    transition!(health[:healthy], health[:error])
  rescue StandardError => e
    transition!(false, e.message)
  end

  private

  attr_reader :monitor

  def fetch_health
    channel = monitor.observed_channel
    api_url = channel.provider_config['api_url'].to_s.chomp('/')
    token = channel.provider_config['instance_token']
    raise 'Evolution Go API URL not configured' if api_url.blank?
    raise 'Evolution Go instance token not configured' if token.blank?

    response = HTTParty.get(
      "#{api_url}/instance/status",
      headers: { 'apikey' => token, 'Content-Type' => 'application/json' },
      timeout: 10
    )
    raise "Evolution Go status HTTP #{response.code}" unless response.success?

    data = response.parsed_response['data'] || response.parsed_response
    connected = ActiveModel::Type::Boolean.new.cast(data['Connected'] || data['connected'])
    logged_in = ActiveModel::Type::Boolean.new.cast(data['LoggedIn'] || data['loggedIn'])
    { healthy: connected && logged_in, error: connected && logged_in ? nil : 'instance disconnected' }
  end

  def transition!(healthy, error)
    monitor.last_checked_at = Time.current
    healthy ? apply_success : apply_failure(error)
    monitor.save!
  end

  def apply_success
    monitor.consecutive_successes += 1
    monitor.consecutive_failures = 0
    monitor.last_error = nil
    return unless monitor.consecutive_successes >= monitor.recovery_threshold

    notify!('RECOVERED') if monitor.last_state == 'degraded'
    monitor.last_state = 'healthy'
  end

  def apply_failure(error)
    monitor.consecutive_failures += 1
    monitor.consecutive_successes = 0
    monitor.last_error = error
    return unless monitor.consecutive_failures >= monitor.failure_threshold

    should_alert = monitor.last_state != 'degraded' || monitor.last_alerted_at.nil? || monitor.last_alerted_at <= monitor.cooldown_minutes.minutes.ago
    notify!('DOWN') if should_alert
    monitor.last_state = 'degraded'
  end

  def notify!(state)
    observed = monitor.observed_channel
    notifier = monitor.notification_channel
    api_url = notifier.provider_config['api_url'].to_s.chomp('/')
    token = notifier.provider_config['instance_token']
    raise 'Notifier Evolution Go API URL not configured' if api_url.blank?
    raise 'Notifier Evolution Go instance token not configured' if token.blank?

    inbox_name = observed.inbox&.name || observed.phone_number
    text = "[Evolution Go Monitor] #{state}: #{inbox_name} (#{observed.phone_number})." \
           " Checked at #{Time.current.utc.iso8601}.#{monitor.last_error.present? ? " Error: #{monitor.last_error}" : ''}"

    Rails.logger.info "[EvolutionGo::HealthMonitor] Sending #{state} alert for #{inbox_name} via notifier"

    response = HTTParty.post(
      "#{api_url}/send/text",
      headers: { 'apikey' => token, 'Content-Type' => 'application/json' },
      body: { number: monitor.recipient_number.delete('+'), text: text, delay: 0 }.to_json,
      timeout: 15
    )
    raise "Evolution Go notification HTTP #{response.code}" unless response.success?

    monitor.last_alerted_at = Time.current
  end
end
