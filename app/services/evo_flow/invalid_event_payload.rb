module EvoFlow
  # Raised when an event payload (track properties / identify traits) is
  # missing a required field or carries a value whose type does not match
  # the schema declared in EvoFlow::EVENT_SCHEMA.
  #
  # F4-style exception: a payload bug is a producer bug, not a transient
  # failure. PublishEventWorker drops it (log + broadcast :evo_flow_publish_dropped)
  # without retry, matching the InvalidEventName contract.
  class InvalidEventPayload < StandardError
    attr_reader :event_name, :field, :reason

    def initialize(event_name:, field:, reason:, details: nil)
      @event_name = event_name
      # L2 fix: field is always a String so alerts/dashboards parsing both
      # Ruby and TS error shapes get the same value.
      @field = field.to_s
      @reason = reason
      details_str = details ? " (#{details})" : ''
      super("Invalid EvoFlow payload for #{event_name.inspect}: #{reason} on field #{@field.inspect}#{details_str}")
    end
  end
end
