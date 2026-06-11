# frozen_string_literal: true

# EVO-1234 [6.5] Migrate channel-coupled message templates into the global /
# independent (channel-less) flow introduced by EVO-1231.
#
# Premise note: the ticket's literal "old models" (per-channel JSONB columns,
# email_templates table) were already migrated AND dropped in Dec 2025
# (20251201132657 et al.). The real remaining gap is that those Dec-migrated
# rows live channel-coupled (channel_id NOT NULL) and therefore never surface in
# the global template menu. This job creates a global (channel_id: nil)
# counterpart for each non-WhatsApp-Cloud channel-coupled template.
#
# Idempotency: each global copy carries
#   external_legacy_id = "message_template:<source_id>"
# backed by a partial unique index, so reruns never duplicate.
#
# Source of truth for results = the returned summary Hash + the structured log.
# Prometheus counters are best-effort instrumentation ONLY: they increment in
# the Sidekiq worker process, are not visible to the web /metrics scrape, and
# reset per process. Specs/ACs assert on the summary Hash, never on the counters.
class MigrateLegacyTemplatesToMessageTemplateJob < ApplicationJob
  queue_as :low

  BATCH_SIZE = 100
  LEGACY_KEY_PREFIX = 'message_template'

  # channel_type => Prometheus `source` label (also used for the summary buckets)
  SOURCE_LABELS = {
    'Channel::Whatsapp' => 'whatsapp_legacy_template',
    'Channel::Instagram' => 'instagram_legacy_template',
    'Channel::FacebookPage' => 'facebook_legacy_template',
    'Channel::Telegram' => 'telegram_legacy_template',
    'Channel::TwilioSms' => 'twilio_sms_legacy_template',
    'Channel::Line' => 'line_legacy_template'
  }.freeze
  DEFAULT_SOURCE_LABEL = 'other_legacy_template'

  # Skip reasons. The four below are the documented taxonomy; specs/ACs assert on
  # these exact keys. `:invalid` (built copy failed validation, e.g. a stray
  # media_type) and `:error` (unexpected exception) are diagnostic buckets.
  REASON_WHATSAPP_CLOUD = :whatsapp_cloud
  REASON_INVALID_CONTENT = :invalid_content
  REASON_ALREADY_MIGRATED = :already_migrated
  REASON_DUPLICATE_NAME = :duplicate_name

  def perform(dry_run: false)
    summary = { migrated: Hash.new(0), skipped: Hash.new(0), dry_run: dry_run }
    # In-run dedup state so dry-run predicts the SAME counts a real run produces
    # (nothing is committed in dry-run, so we cannot rely on DB lookups alone).
    ctx = {
      dry_run: dry_run,
      summary: summary,
      seen_keys: Set.new,    # external_legacy_id keys produced this run
      all_names: Set.new,    # every global name produced this run (downcased)
      legacy_names: Set.new  # global names produced by THIS migration this run (downcased)
    }

    MessageTemplate.where.not(channel_id: nil).find_in_batches(batch_size: BATCH_SIZE) do |batch|
      batch.each do |source|
        migrate_one(source, ctx)
      rescue StandardError => e
        Rails.logger.error(
          "[migrate_legacy_templates] source_id=#{source.id} error=#{e.class}: #{e.message}"
        )
        summary[:skipped][:error] += 1
      end
    end

    Rails.logger.info(
      "[migrate_legacy_templates] done dry_run=#{dry_run} " \
      "migrated=#{summary[:migrated].to_h} skipped=#{summary[:skipped].to_h}"
    )
    summary
  end

  private

  def migrate_one(source, ctx)
    # 1. WhatsApp Cloud (or an unverifiable WhatsApp channel) stays channel-bound:
    #    Meta requires an approved template tied to a WABA channel (EVO-1232).
    return skip(ctx, REASON_WHATSAPP_CLOUD, source, 'kept channel-bound (WhatsApp)') if keep_channel_bound?(source)

    # 2. Blank content cannot satisfy the model's presence validation.
    return skip(ctx, REASON_INVALID_CONTENT, source, 'blank content') if source.content.blank?

    # 3. Idempotency: skip rows already migrated (committed) or seen this run.
    key = legacy_key(source)
    if ctx[:seen_keys].include?(key) || MessageTemplate.exists?(external_legacy_id: key)
      return skip(ctx, REASON_ALREADY_MIGRATED, source, 'already migrated')
    end

    # 4. Resolve the global name (dedupe vs other legacy rows, suffix vs admin globals).
    target_name = resolve_name(source, ctx)
    return skip(ctx, REASON_DUPLICATE_NAME, source, 'another legacy row already owns this name') if target_name == :duplicate

    attrs = build_attrs(source, key, target_name)

    if ctx[:dry_run]
      candidate = MessageTemplate.new(attrs)
      unless candidate.valid?
        return skip(ctx, :invalid, source, candidate.errors.full_messages.join('; '))
      end
    else
      MessageTemplate.create!(attrs)
      increment_migrated_metric(source_label(source))
    end

    record_success(ctx, source, target_name, key)
  end

  # WhatsApp Cloud detection. A WhatsApp-typed row whose channel record is gone
  # is treated conservatively as "keep channel-bound": we cannot read its
  # provider, so we refuse to risk globalizing a former Cloud template (F12).
  def keep_channel_bound?(source)
    return false unless source.channel_type == 'Channel::Whatsapp'

    channel = source.channel
    return true if channel.nil? # provider unverifiable -> conservative

    channel.provider == 'whatsapp_cloud'
  end

  # Returns the global name to use, or :duplicate when another legacy migration
  # row already owns this base name (one global per legacy name is enough).
  def resolve_name(source, ctx)
    base = source.name
    base_key = base.downcase

    # Owned by a legacy migration already (this run OR committed) -> duplicate.
    return :duplicate if ctx[:legacy_names].include?(base_key) || legacy_global_exists?(base)

    # Free among all globals -> use as-is.
    return base unless global_name_taken?(base, ctx)

    # Collides with a genuine pre-existing (admin-created) global -> suffix.
    suffixed = "#{base} (legacy)"
    return suffixed unless global_name_taken?(suffixed, ctx)

    "#{base} (legacy #{source.id})"
  end

  def legacy_global_exists?(name)
    MessageTemplate.where(channel_id: nil, name: name).where.not(external_legacy_id: nil).exists?
  end

  def global_name_taken?(name, ctx)
    ctx[:all_names].include?(name.downcase) ||
      MessageTemplate.where(channel_id: nil, name: name).exists?
  end

  def build_attrs(source, key, name)
    {
      channel: nil,
      name: name,
      external_legacy_id: key,
      content: source.content,
      language: source.language,
      category: source.category,
      template_type: normalized_template_type(source.template_type),
      components: deep_dup(source.components),
      # NOTE (F5): the model's before_save re-derives `variables` from {{tokens}}
      # in `content`. Legacy rows carry synthetic component-derived var names
      # (var_1, var_2...) that are NOT present in content, so they are dropped on
      # save and the copy's variables reflect the real content tokens. This copy
      # only survives for vars whose names actually appear in content.
      variables: deep_dup(source.variables),
      media_url: source.media_url,
      media_type: source.media_type.presence, # '' -> nil so inclusion+allow_nil passes (F6)
      settings: deep_dup(source.settings),
      metadata: deep_dup(source.metadata)
    }
  end

  # The Dec-2025 migration only ever wrote text/media/interactive (all valid enum
  # keys). Guard defensively anyway: an out-of-enum value raises ArgumentError at
  # assignment, so fall back to the model default (set_defaults => 'text').
  def normalized_template_type(value)
    MessageTemplate.template_types.key?(value) ? value : nil
  end

  def record_success(ctx, source, name, key)
    ctx[:all_names] << name.downcase
    ctx[:legacy_names] << name.downcase
    ctx[:seen_keys] << key
    ctx[:summary][:migrated][source_label(source)] += 1
  end

  def skip(ctx, reason, source, detail)
    Rails.logger.info(
      "[migrate_legacy_templates] skip reason=#{reason} source_id=#{source.id} " \
      "name=#{source.name.inspect} detail=#{detail}"
    )
    ctx[:summary][:skipped][reason] += 1
    increment_skipped_metric(reason) unless ctx[:dry_run]
    nil
  end

  def legacy_key(source)
    "#{LEGACY_KEY_PREFIX}:#{source.id}"
  end

  def source_label(source)
    SOURCE_LABELS.fetch(source.channel_type, DEFAULT_SOURCE_LABEL)
  end

  def deep_dup(value)
    value.respond_to?(:deep_dup) ? value.deep_dup : value
  end

  # Best-effort metrics. Guarded so a missing constant or registry hiccup never
  # aborts a migration row.
  def increment_migrated_metric(label)
    return unless defined?(EVO_AI_CRM_TEMPLATES_MIGRATED_COUNTER)

    EVO_AI_CRM_TEMPLATES_MIGRATED_COUNTER.increment(labels: { source: label })
  rescue StandardError => e
    Rails.logger.warn("[migrate_legacy_templates] migrated metric failed: #{e.message}")
  end

  def increment_skipped_metric(reason)
    return unless defined?(EVO_AI_CRM_TEMPLATES_MIGRATED_SKIPPED_COUNTER)

    EVO_AI_CRM_TEMPLATES_MIGRATED_SKIPPED_COUNTER.increment(labels: { reason: reason.to_s })
  rescue StandardError => e
    Rails.logger.warn("[migrate_legacy_templates] skipped metric failed: #{e.message}")
  end
end
