module EvoFlow
  class InvalidEventName < StandardError
    def initialize(event_name)
      super("Unknown EvoFlow event_name: #{event_name.inspect}. Allowed: #{EvoFlow::EVENT_NAMES.join(', ')}")
    end
  end
end
