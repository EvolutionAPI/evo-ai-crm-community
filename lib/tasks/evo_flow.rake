# Backfill historical contact_events to evo-flow.
#
# Usage:
#   bundle exec rake evo_flow:backfill              # ALL records, dry-run (default)
#   bundle exec rake evo_flow:backfill[<id>]        # one account_id, dry-run (upstream parity)
#   DRY_RUN=false bundle exec rake evo_flow:backfill[<id>]  # real publish (dev/stage)
#   FROM_DATE=2026-04-01T00:00:00Z bundle exec rake evo_flow:backfill
#   # Production hard-stop: CONFIRM is required for any non-dry-run.
#   DRY_RUN=false CONFIRM=I_KNOW_WHAT_IM_DOING bundle exec rake evo_flow:backfill
#
# ⚠️ Do NOT run with DRY_RUN=false in production until evo-flow story 2.4
# (IdempotencyService) ships — reruns duplicate events in ClickHouse.
# See README "Backfill EvoFlow contact_events" for full operating guidance.
namespace :evo_flow do
  # account_id arg is accepted for upstream/Chatwoot parity. This community
  # fork is single-tenant: the value only partitions cursor and metric keys,
  # not record selection.
  desc 'Backfill historical contact_events to evo-flow (DRY_RUN=true default; CONFIRM gates prod).'
  task :backfill, [:account_id] => :environment do |_, args|
    dry_run = ENV.fetch('DRY_RUN', 'true').to_s.casecmp('true').zero?

    raw_from_date = ENV.fetch('FROM_DATE', nil)
    from_date = raw_from_date.to_s.strip.empty? ? 1.year.ago : Time.iso8601(raw_from_date)

    if Rails.env.production? && !dry_run && ENV['CONFIRM'] != 'I_KNOW_WHAT_IM_DOING'
      raise 'Refusing to run real backfill in production without CONFIRM=I_KNOW_WHAT_IM_DOING'
    end

    EvoFlow::BackfillContactEventsWorker.perform_async(
      args[:account_id]&.to_s,
      'dry_run' => dry_run,
      'from_date' => from_date.iso8601
    )

    puts "[evo_flow:backfill] enqueued: account_id=#{args[:account_id] || 'ALL'} " \
         "dry_run=#{dry_run} from_date=#{from_date.iso8601}"
  end
end
