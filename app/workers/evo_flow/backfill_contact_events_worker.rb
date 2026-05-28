module EvoFlow
  # Backfills historical contact_events into evo-flow's ClickHouse via the
  # batch endpoint, so the contact-events timeline is populated for contacts
  # that existed before the live publisher (EvoFlow::PublishEventWorker)
  # shipped.
  #
  # retry: 2 (lower than PublishEventWorker's 5) because the worker is
  # resumable via a Redis cursor — a hard failure is preferable to long
  # retry storms; reruns continue from the cursor.
  #
  # Diverges from PublishEventWorker on InvalidEventName: the live worker
  # drops (defense-in-depth), the backfill RAISES so an incomplete
  # BackfillMapper is loud, not silent.
  #
  # NOTE: this community fork is single-tenant (no Account model,
  # Message/Conversation/ReportingEvent carry no account_id). The
  # `account_id` perform arg is accepted for forward/upstream compatibility
  # but only adjusts cursor/metric key partitioning when non-nil.
  #
  # ⚠️ Production usage requires evo-flow's IdempotencyService to be
  # deployed first — without dedup, reruns duplicate events in ClickHouse
  # (MergeTree has no native dedup). See README.
  class BackfillContactEventsWorker # rubocop:disable Metrics/ClassLength
    include Sidekiq::Worker
    sidekiq_options queue: :integrations, retry: 2

    # Matches evo-flow's TrackBatchEventsDto internal BATCH_SIZE constant
    # in src/modules/config/processing.config.ts — keep in lockstep.
    BATCH_SIZE = 100
    SCAN_BATCH_SIZE = 1000
    DEFAULT_FROM_DATE_LAG = 1.year
    METRIC_NAMESPACE = 'evo_flow_backfill'.freeze

    sidekiq_retries_exhausted do |job, ex|
      args = job['args'] || []
      account_id = args[0]
      safe_error = EvoFlow::PublishEventWorker.sanitize_error(ex)
      Rails.logger.error(
        "[EvoFlow][Backfill] terminal failure account_id=#{account_id || 'ALL'} msg=#{safe_error}"
      )
      # `source` is intentionally omitted here — Sidekiq's exhaustion block
      # has no live worker state, and threading it through job args added
      # no signal (always '<unknown>'). broadcast_dropped still carries
      # source where it is meaningful (F4 rescues).
      EvoFlow::BackfillFailureBroadcaster.new.broadcast_failed(
        account_id: account_id, error: safe_error
      )
    end

    def perform(account_id = nil, opts = {})
      @account_id = account_id
      return log_disabled unless EvoFlow.enabled?

      configure_run(opts)
      run_source(:message, relation: messages_relation) { |msg| build_message_payload(msg) }
      run_source(:reporting_event, relation: reporting_events_relation) { |re| build_reporting_event_payload(re) }
    rescue EvoFlow::InvalidEventName => e
      handle_invalid_event_name(e)
      raise
    rescue EvoFlow::ConfigurationError => e
      handle_configuration_error(e)
      nil
    end

    private

    def configure_run(opts)
      opts = (opts || {}).transform_keys(&:to_s)
      @dry_run = opts.fetch('dry_run', true)
      @from_date = parse_from_date(opts['from_date'])
      @client = EvoFlow::Client.new unless @dry_run
      @sample_logged = Set.new
    end

    # find_each enforces its own primary-key ASC ordering. Passing
    # `start: cursor` (Rails 6+) is UUID-safe — it becomes the lower bound
    # on the PK, no manual where-clause comparison against the uuid column.
    def run_source(source, relation:) # rubocop:disable Metrics/MethodLength
      cursor_key = cursor_key_for(source)
      cursor = Redis::Alfred.get(cursor_key).presence
      find_each_opts = { batch_size: SCAN_BATCH_SIZE }
      find_each_opts[:start] = cursor if cursor

      buffer = []
      processed = 0
      relation.find_each(**find_each_opts) do |record|
        payload = yield(record)
        if payload.nil?
          increment_metric(:skipped, type: source)
          next
        end

        log_sample(payload, source)
        buffer << [record.id, payload]
        processed += 1
        flush(buffer, source: source, cursor_key: cursor_key) if buffer.size >= BATCH_SIZE
      end

      flush(buffer, source: source, cursor_key: cursor_key) if buffer.any?
      log_summary(source: source, count: processed)
      finalize_cursor(cursor_key)
    end

    def messages_relation
      Message
        .where(message_type: :activity)
        .where('messages.created_at >= ?', @from_date)
    end

    def reporting_events_relation
      ReportingEvent
        .where('event_start_time >= ?', @from_date)
        .joins(:conversation)
    end

    # Conversation enforces `validates :contact_id, presence: true` and
    # belongs_to :contact is non-optional, so contact_id is normally never
    # nil. Still guarded against raw INSERTs / migration backfills bypassing
    # ActiveRecord validation.
    def build_message_payload(msg)
      conversation = msg.conversation
      return nil if conversation.nil? || conversation.contact_id.nil? || msg.created_at.nil?

      EvoFlow::PayloadBuilder.build_track(
        event_name: 'conversation.activity',
        contact_id: conversation.contact_id,
        properties: {
          message_content: msg.content,
          conversation_id: msg.conversation_id,
          sender_type: msg.sender_type,
          sender_id: msg.sender_id
        },
        occurred_at: msg.created_at,
        message_id: EvoFlow::BackfillMapper.message_id_for(:message, msg.id)
      )
    end

    def build_reporting_event_payload(reporting_event)
      conversation = reporting_event.conversation
      return nil if conversation.nil? || conversation.contact_id.nil?
      return nil if reporting_event.event_start_time.nil?

      EvoFlow::PayloadBuilder.build_track(
        event_name: EvoFlow::BackfillMapper.map_reporting_event_to_event_name(reporting_event),
        contact_id: conversation.contact_id,
        properties: {
          conversation_id: reporting_event.conversation_id,
          user_id: reporting_event.user_id,
          value: reporting_event.value,
          value_in_business_hours: reporting_event.value_in_business_hours
        },
        occurred_at: reporting_event.event_start_time,
        message_id: EvoFlow::BackfillMapper.message_id_for(:reporting_event, reporting_event.id)
      )
    end

    def flush(buffer, source:, cursor_key:)
      return if buffer.empty?

      payloads = buffer.map { |(_, payload)| payload }
      last_id = buffer.last[0]

      if @dry_run
        log_dry_run_flush(source: source, count: payloads.size, cursor: last_id)
      else
        post_batch_or_record_failure(payloads, source: source)
        Redis::Alfred.set(cursor_key, last_id)
      end

      buffer.size.times { increment_metric(:processed, type: source) }
      log_flush(source: source, count: payloads.size, cursor: last_id) unless @dry_run
      buffer.clear
    end

    # On HTTPError we increment :flush_attempts_failed (not :failed) so the
    # counter reflects *attempts*, not unique records — Sidekiq's retries
    # would otherwise multiply the count per record by (retry+1).
    # The terminal failure broadcast in sidekiq_retries_exhausted is what
    # carries "this batch is unrecoverable" semantics.
    def post_batch_or_record_failure(payloads, source:)
      @client.post_batch(payloads)
    rescue EvoFlow::HTTPError => e
      Rails.logger.warn(
        "[EvoFlow][Backfill] flush failed (will retry) source=#{source} " \
        "count=#{payloads.size} code=#{e.code} msg=#{e.message} " \
        "sample=#{EvoFlow::PublishEventWorker.sanitize_payload(payloads.first).inspect}"
      )
      increment_metric(:flush_attempts_failed, type: source)
      raise
    end

    def finalize_cursor(cursor_key)
      return if @dry_run

      Redis::Alfred.delete(cursor_key)
    end

    # Cursor key partitions by from_date at YYYY-MM-DD granularity — a
    # re-run with a different *date* doesn't reuse a cursor that covered a
    # narrower window. Two runs that differ only in sub-day hours WILL
    # share a cursor (calendar-day partitioning is the common case).
    def cursor_key_for(source)
      window = @from_date.utc.strftime('%Y-%m-%d')
      base =
        if @account_id.nil?
          "backfill:cursor:#{window}:#{source}"
        else
          "backfill:cursor:#{@account_id}:#{window}:#{source}"
        end
      @dry_run ? "dry_run:#{base}" : base
    end

    def increment_metric(name, type:)
      parts = [METRIC_NAMESPACE, name]
      parts << @account_id unless @account_id.nil?
      parts << type
      key = parts.compact.join(':')
      key = "dry_run:#{key}" if @dry_run
      Redis::Alfred.incr(key)
    end

    def log_summary(source:, count:)
      prefix = @dry_run ? 'would_backfill' : 'backfilled'
      Rails.logger.info(
        "[EvoFlow][Backfill] #{prefix} account=#{@account_id || 'ALL'} type=#{source} count=#{count}"
      )
    end

    # One sample line per source so debug output covers both Message and
    # ReportingEvent payload shapes, not just the first one encountered.
    def log_sample(payload, source)
      return if @sample_logged.include?(source)

      @sample_logged << source
      sanitized = EvoFlow::PublishEventWorker.sanitize_payload(payload.transform_keys(&:to_s))
      Rails.logger.info("[EvoFlow][Backfill] sample_payload source=#{source} payload=#{sanitized.inspect}")
    end

    def log_dry_run_flush(source:, count:, cursor:)
      Rails.logger.info(
        "[EvoFlow][Backfill] dry_run flush source=#{source} count=#{count} cursor=#{cursor}"
      )
    end

    def log_flush(source:, count:, cursor:)
      Rails.logger.info(
        "[EvoFlow][Backfill] flushed source=#{source} count=#{count} cursor=#{cursor}"
      )
    end

    def log_disabled
      Rails.logger.warn(
        '[EvoFlow][Backfill] skipped: EvoFlow integration is disabled ' \
        '(set EVO_FLOW_ENABLED=true or configure AUTH_APIKEY_INTEGRATION_LOCAL)'
      )
      nil
    end

    # Fail loud on malformed FROM_DATE — silent fallback to 1.year.ago would
    # process the wrong window without an operator noticing. The rake task
    # validates upfront; this guards direct perform_async callers (console,
    # specs, future schedulers).
    def parse_from_date(raw)
      return Time.current - DEFAULT_FROM_DATE_LAG if raw.nil? || raw.to_s.strip.empty?

      Time.iso8601(raw)
    end

    def handle_invalid_event_name(error)
      Rails.logger.error(
        "[EvoFlow][Backfill] invalid_event_name account_id=#{@account_id || 'ALL'} " \
        "msg=#{error.message}"
      )
      EvoFlow::BackfillFailureBroadcaster.new.broadcast_dropped(
        reason: :invalid_event_name, account_id: @account_id,
        source: 'reporting_event', error_message: error.message
      )
    end

    def handle_configuration_error(error)
      Rails.logger.error(
        "[EvoFlow][Backfill] dropped: configuration_error account_id=#{@account_id || 'ALL'} " \
        "msg=#{error.message}"
      )
      EvoFlow::BackfillFailureBroadcaster.new.broadcast_dropped(
        reason: :configuration_error, account_id: @account_id,
        source: '<startup>', error_message: error.message
      )
    end
  end
end
