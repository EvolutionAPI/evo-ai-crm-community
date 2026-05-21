module EvoFlow
  # Pure Sidekiq worker (repo convention: include Sidekiq::Worker, lives in
  # app/workers/). retry: 5 overrides the global sidekiq.yml max_retries: 3.
  #
  # On retry exhaustion the sidekiq_retries_exhausted hook fires and the job
  # lands in the (default-on) Dead Set, broadcasting Wisper
  # :evo_flow_publish_failed for downstream handling (listener wired later).
  # Honest caveat: this hook runs in-process on the final attempt; if that
  # process is hard-killed (OOM/SIGKILL) the hook does not run — terminal
  # alerting then relies on Dead Set monitoring, not this broadcast.
  #
  # Signature is perform(path, payload) — Client#post needs the target path;
  # documented divergence from EVO-1238's perform(payload).
  #
  # Exceptions to F4: EvoFlow::InvalidEventName and EvoFlow::ConfigurationError
  # are NOT retried — both are code/config bugs, not transient failures
  # (rescued earliest in #perform, logged + dropped). Configuration won't fix
  # itself on retry; retrying just floods the Dead Set with the same env-var
  # error and triggers spurious :evo_flow_publish_failed broadcasts.
  class PublishEventWorker
    include Sidekiq::Worker
    sidekiq_options queue: :integrations, retry: 5

    # Event content may carry PII (contact traits/properties). It is redacted
    # before being persisted as Sidekiq job args / Dead Set / Wisper payload;
    # only identifiers needed for triage and replay decisions are kept.
    PII_KEYS = %w[properties traits].freeze
    MAX_ERROR_MESSAGE = 500
    # Heuristic redaction for likely secrets/tokens embedded in error messages
    # (>=32 hex/base64 chars). Conservative: catches API keys, JWTs, SHA256
    # hex digests, etc., without touching short human-readable text.
    LIKELY_SECRET = %r{[A-Za-z0-9+/_=-]{32,}}

    # Wisper 2.0.0 exposes NO `Wisper.publish`; global listeners registered via
    # `Wisper.subscribe` (config/initializers/contact_company_listeners.rb) are
    # notified by any Wisper::Publisher#broadcast. `publish` is private, so
    # wrap it. Mirrors the repo idiom in Contacts::BulkTransferService.
    class FailureBroadcaster
      include Wisper::Publisher

      def broadcast_failed(path:, payload:, error:)
        publish('evo_flow_publish_failed', data: { path: path, payload: payload, error: error })
      end
    end

    def self.sanitize_payload(payload)
      return payload unless payload.is_a?(Hash)

      payload.each_with_object({}) do |(key, value), acc|
        acc[key] = PII_KEYS.include?(key.to_s) ? '[redacted]' : value
      end
    end

    # For EvoFlow::HTTPError the message is already passed through Client#safe_body;
    # for JSON::ParserError / ArgumentError / TLS errors it may still echo a
    # response snippet. Bound length and redact long token-looking substrings.
    # Idempotent.
    def self.sanitize_error(error)
      msg = error.message.to_s.gsub(LIKELY_SECRET, '[redacted]')
      msg.length > MAX_ERROR_MESSAGE ? "#{msg[0, MAX_ERROR_MESSAGE]}... (truncated)" : msg
    end

    sidekiq_retries_exhausted do |job, ex|
      args = job['args'] || []
      path = args[0]
      safe_payload = EvoFlow::PublishEventWorker.sanitize_payload(args[1])
      safe_error = EvoFlow::PublishEventWorker.sanitize_error(ex)
      Rails.logger.error("[EvoFlow] terminal failure path=#{path} msg=#{safe_error}")
      FailureBroadcaster.new.broadcast_failed(path: path, payload: safe_payload, error: safe_error)
    end

    def perform(path, payload)
      EvoFlow::Client.new.post(path, payload)
      Rails.logger.info("[EvoFlow] published path=#{path} messageId=#{message_id(payload)}")
    rescue EvoFlow::InvalidEventName => e
      # F4 exception: code bug, not transient — log and drop so Sidekiq treats
      # the job as success (no retry, no Dead Set entry, no Wisper broadcast).
      # MUST stay above the StandardError rescue (InvalidEventName < StandardError).
      Rails.logger.error("[EvoFlow] dropped: invalid event_name path=#{path} msg=#{e.message}")
      nil
    rescue EvoFlow::ConfigurationError => e
      # F4 exception: env/config bug, not transient. Retrying just floods the
      # Dead Set with the same env-var error and triggers spurious
      # :evo_flow_publish_failed broadcasts. Surface the bug via a single
      # error log instead. MUST stay above the StandardError rescue.
      Rails.logger.error("[EvoFlow] dropped: configuration error path=#{path} msg=#{e.message}")
      nil
    rescue EvoFlow::HTTPError => e
      Rails.logger.warn(
        "[EvoFlow] publish failed (will retry) path=#{path} code=#{e.code} msg=#{e.message}"
      )
      raise
    rescue StandardError => e
      # Any other failure (unparseable body, bad args, config error) must also
      # count as a Sidekiq retry and reach the exhaustion path uniformly.
      Rails.logger.warn(
        "[EvoFlow] publish errored (will retry) path=#{path} msg=#{self.class.sanitize_error(e)}"
      )
      raise
    end

    private

    # Sidekiq JSON-serialises args → string keys for enqueued jobs; tolerate
    # symbol keys too (in-process / console invocation with builder output).
    # Returns '<missing>' (not '') when absent, so logs are greppable.
    def message_id(payload)
      return '<missing>' unless payload.is_a?(Hash)

      payload['messageId'] || payload[:messageId] || '<missing>'
    end
  end
end
