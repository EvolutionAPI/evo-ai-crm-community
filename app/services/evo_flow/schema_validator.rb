module EvoFlow
  # Validates an event payload (properties for track, traits for identify)
  # against the schema declared in EvoFlow::EVENT_SCHEMA.
  #
  # Called from EvoFlow::PayloadBuilder.build_track / build_identify after
  # validate_event_name!. Raises EvoFlow::InvalidEventPayload, which the
  # worker treats the same as InvalidEventName: log + drop + broadcast
  # :evo_flow_publish_dropped, no retry.
  class SchemaValidator
    UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze

    def self.validate!(event_name, payload)
      schema = EvoFlow::EventSchema.fetch(event_name)
      return if schema.nil?

      normalized = stringify_keys(payload)

      schema[:required].each do |field, type|
        value = normalized[field.to_s]
        if missing?(value, type)
          raise EvoFlow::InvalidEventPayload.new(
            event_name: event_name, field: field.to_s, reason: :missing_required
          )
        end
        assert_type!(event_name, field, type, value)
      end

      schema[:optional].each do |field, type|
        value = normalized[field.to_s]
        next if missing?(value, type)

        assert_type!(event_name, field, type, value)
      end
    end

    # AC3: a required field is missing when it is nil OR an empty string for
    # string-like types. false/0 stay valid for their types.
    def self.missing?(value, type)
      return true if value.nil?
      return true if [:string, :uuid].include?(type) && value.is_a?(String) && value.empty?

      false
    end
    private_class_method :missing?

    def self.stringify_keys(hash)
      return {} if hash.nil?

      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end
    private_class_method :stringify_keys

    def self.assert_type!(event_name, field, type, value)
      return if matches_type?(type, value)

      raise EvoFlow::InvalidEventPayload.new(
        event_name: event_name, field: field.to_s, reason: :invalid_type,
        details: "expected #{type}, got #{value.class}"
      )
    end
    private_class_method :assert_type!

    def self.matches_type?(type, value)
      case type
      when :string then value.is_a?(String)
      when :number then value.is_a?(Numeric)
      when :boolean then [true, false].include?(value)
      when :object then value.is_a?(Hash)
      when :uuid then matches_uuid?(value)
      when :date then matches_date?(value)
      else false
      end
    end
    private_class_method :matches_type?

    # Listeners pass UUIDs as canonical strings AND raw integers (legacy
    # contact_id paths). Accept canonical UUIDs, numeric strings (string-encoded
    # legacy ids), or any Numeric value. Arbitrary strings like "hello" are
    # rejected so the :uuid type does not lie about validation.
    def self.matches_uuid?(value)
      return true if value.is_a?(Integer) || value.is_a?(Numeric)
      return false unless value.is_a?(String)
      return false if value.empty?
      return true if UUID_REGEX.match?(value)

      !!(Integer(value) rescue false)
    end
    private_class_method :matches_uuid?

    def self.matches_date?(value)
      return true if value.respond_to?(:iso8601)
      return false unless value.is_a?(String)

      Time.iso8601(value)
      true
    rescue ArgumentError
      false
    end
    private_class_method :matches_date?
  end
end
