# Re-asks the provider whether a token-based channel's credential still works.
#
# The probe that runs on save proves the credential worked the day it was
# written. A credential revoked at the provider afterwards — outside the Hub
# flow, which has its own disconnect event — leaves no trace in the CRM, so the
# channel reads connected forever. This job is what asks again.
class Channels::Whatsapp::CredentialProbeSchedulerJob < ApplicationJob
  queue_as :low

  # Target interval between two probes of the same channel. With the batch
  # ceiling below and an hourly cron, an installation of up to
  # BULK_EXTERNAL_HTTP_CALLS_LIMIT * 6 token channels is fully covered inside
  # the window; past that the backlog drains later, still well inside
  # Channels::ConnectionStateResolver::CREDENTIALS_TTL.
  PROBE_INTERVAL = 6.hours

  # The stamp format written by Channel::Whatsapp#stamp_credentials_verified.
  # Anything else is not a timestamp we can compare, so it counts as no
  # evidence and the channel goes back in the queue — the same rule the
  # resolver applies when it reads the stamp.
  STAMP_FORMAT = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'.freeze

  def perform
    due_channels.each { |channel| Channels::Whatsapp::CredentialProbeJob.perform_later(channel) }
  end

  private

  def due_channels
    Channel::Whatsapp
      .where(provider: Channel::Whatsapp::CREDENTIAL_PROBE_PROVIDERS)
      .where(not_hub_managed_sql)
      .where(stale_stamp_sql, cutoff: PROBE_INTERVAL.ago.utc.iso8601)
      .order(Arel.sql(oldest_first_sql))
      .limit(Limits::BULK_EXTERNAL_HTTP_CALLS_LIMIT)
  end

  # Mirrors Channel::Whatsapp#hub_managed?, which asks whether the block is a
  # Hash. COALESCE, not `<>` alone: a channel with no block at all compares
  # NULL, and NULL would drop the row instead of keeping it.
  def not_hub_managed_sql
    "COALESCE(jsonb_typeof(provider_config -> 'evolution_hub'), '') <> 'object'"
  end

  # Compared as text, not cast to a timestamp: a channel carrying a malformed
  # stamp would blow up the whole batch on the cast, and it is exactly the
  # channel most in need of a fresh probe. Same-format UTC strings order
  # identically as text and as timestamps.
  def stale_stamp_sql
    "COALESCE(provider_connection ->> 'credentials_verified_at', '') !~ '#{STAMP_FORMAT}' " \
      "OR provider_connection ->> 'credentials_verified_at' < :cutoff"
  end

  # Collapses "never probed" and "unreadable stamp" to the same empty string so
  # both sort ahead of every real timestamp.
  def oldest_first_sql
    "CASE WHEN COALESCE(provider_connection ->> 'credentials_verified_at', '') ~ '#{STAMP_FORMAT}' " \
      "THEN provider_connection ->> 'credentials_verified_at' ELSE '' END ASC"
  end
end
