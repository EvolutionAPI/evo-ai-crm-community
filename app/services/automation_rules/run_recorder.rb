class AutomationRules::RunRecorder
  STATUS_MATCHED = 'matched'.freeze
  STATUS_NO_MATCH = 'no_match'.freeze
  STATUS_ERROR = 'error'.freeze
  STATUS_SKIPPED = 'skipped'.freeze

  STEP_LEVELS = %w[info success warn error].freeze

  attr_reader :rule, :event_name

  def initialize(rule:, event_name:, payload: {})
    @rule = rule
    @event_name = event_name
    @payload = payload
    @steps = []
    @started_at = Time.zone.now
    @status = STATUS_NO_MATCH
    @error_message = nil
    @actions_skipped = false
  end

  # An action refused itself mid-run (e.g. an archived pipeline destination). The rule
  # still matched, but the final status must not read as a clean success — matched! checks
  # this so the timeline's "Skipped" step is not contradicted by a green result.
  def action_skipped!(label, data: {})
    @actions_skipped = true
    add_step(label, level: 'warn', data: data)
  end

  def add_step(label, level: 'info', data: {})
    level = 'info' unless STEP_LEVELS.include?(level.to_s)
    @steps << {
      at: Time.zone.now.iso8601(3),
      label: label,
      level: level,
      data: data
    }
  end

  def matched!
    @status = @actions_skipped ? STATUS_SKIPPED : STATUS_MATCHED
  end

  def no_match!
    @status = STATUS_NO_MATCH
  end

  def skipped!(reason)
    @status = STATUS_SKIPPED
    add_step("Skipped: #{reason}", level: 'warn')
  end

  def error!(exception)
    @status = STATUS_ERROR
    @error_message = "#{exception.class}: #{exception.message}"
    add_step('Execution raised an error', level: 'error', data: { error: @error_message })
  end

  def persist!
    finished_at = Time.zone.now
    AutomationRuleRun.create!(
      automation_rule: @rule,
      event_name: @event_name,
      status: @status,
      started_at: @started_at,
      finished_at: finished_at,
      duration_ms: ((finished_at - @started_at) * 1000).to_i,
      error_message: @error_message,
      payload: sanitize(@payload),
      steps: @steps
    )
  rescue StandardError => e
    Rails.logger.error "[AutomationRules::RunRecorder] failed to persist run for rule=#{@rule&.id}: #{e.class}: #{e.message}"
    nil
  end

  private

  # Avoid serializing huge ActiveRecord objects; keep ids and basic identifiers.
  def sanitize(payload)
    payload.transform_values do |value|
      case value
      when ActiveRecord::Base
        { type: value.class.name, id: value.id }
      when Hash
        value
      else
        value
      end
    end
  rescue StandardError
    {}
  end
end
