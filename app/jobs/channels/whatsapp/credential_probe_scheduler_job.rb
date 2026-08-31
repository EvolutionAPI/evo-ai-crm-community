# Re-asks the provider whether a token-based channel's credential still works.
# The probe that runs on save only proves the credential worked that day; a
# credential revoked afterwards leaves no trace, so the channel reads connected
# forever. This job is what asks again.
class Channels::Whatsapp::CredentialProbeSchedulerJob < ApplicationJob
  queue_as :low

  # Target interval between two probes of the same channel, kept far below
  # Channels::ConnectionStateResolver::CREDENTIALS_TTL so queue backlog never
  # degrades a healthy channel.
  PROBE_INTERVAL = 6.hours

  # The stamp format written by Channel::Whatsapp#record_credential_probe!.
  STAMP_FORMAT = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'.freeze

  def perform
    due_channels.each { |channel| Channels::Whatsapp::CredentialProbeJob.perform_later(channel) }
  end

  private

  # Ordered by attempt, not by evidence: a channel the provider keeps rejecting
  # never refreshes credentials_verified_at, so ordering by that would park it
  # at the head of every batch and starve the healthy channels behind it.
  def due_channels
    Channel::Whatsapp
      .joins(:inbox)
      .where(provider: Channel::Whatsapp::CREDENTIAL_PROBE_PROVIDERS)
      .where(not_hub_managed_sql)
      .where(due_sql, cutoff: PROBE_INTERVAL.ago.utc.iso8601, now: Time.current.utc.iso8601)
      .order(Arel.sql(oldest_first_sql))
      .limit(Limits::BULK_EXTERNAL_HTTP_CALLS_LIMIT)
  end

  # Mirrors Channel::Whatsapp#hub_managed?. COALESCE, not `<>` alone: a channel
  # with no block at all compares NULL, and NULL would drop the row.
  def not_hub_managed_sql
    "COALESCE(jsonb_typeof(provider_config -> 'evolution_hub'), '') <> 'object'"
  end

  # Compared as text, not cast: a malformed stamp would blow up the batch on
  # the cast, and it is exactly the channel most in need of a probe. A stamp in
  # the future is not evidence either — the resolver already refuses it.
  def due_sql
    "#{probed_at} !~ '#{STAMP_FORMAT}' OR #{probed_at} < :cutoff OR #{probed_at} > :now"
  end

  def oldest_first_sql
    "CASE WHEN #{probed_at} ~ '#{STAMP_FORMAT}' THEN #{probed_at} ELSE '' END ASC"
  end

  def probed_at
    "COALESCE(provider_connection ->> 'credentials_probed_at', '')"
  end
end
