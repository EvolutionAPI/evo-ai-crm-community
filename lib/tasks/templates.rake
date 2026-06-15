# frozen_string_literal: true

# EVO-1234 [6.5] Operator tasks for porting channel-coupled message templates
# into the global/independent flow.
#
# Usage:
#   DRY_RUN=true bundle exec rake templates:migrate_legacy   # preview, no writes
#   bundle exec rake templates:migrate_legacy                # apply (idempotent)
#   bundle exec rake templates:rollback_legacy_migration     # delete migrated globals
#
# The migration is idempotent (safe to rerun). The job runs inline via
# perform_now so the operator watches the log stream and gets the summary back.
namespace :templates do
  desc 'Migrate channel-coupled templates into the global flow (DRY_RUN=true to preview)'
  task migrate_legacy: :environment do
    dry_run = ENV['DRY_RUN'] == 'true'
    summary = MigrateLegacyTemplatesToMessageTemplateJob.perform_now(dry_run: dry_run)
    puts "[templates:migrate_legacy] dry_run=#{dry_run} #{summary.except(:dry_run).inspect}"
    puts '[templates:migrate_legacy] DRY RUN — no rows were written. Re-run without DRY_RUN to apply.' if dry_run

    # The job only buckets a row under :error when an UNEXPECTED exception is
    # rescued (expected skips use their own reasons). Surface that as a non-zero
    # exit AFTER printing the summary, so operators/CI never read a partially
    # failed run as success. Applies to dry-run too: a dry-run that errors is
    # predicting a broken real run. (skipped is a Hash.new(0) — always Integer.)
    errors = summary[:skipped][MigrateLegacyTemplatesToMessageTemplateJob::REASON_ERROR]
    abort("[templates:migrate_legacy] FAILED: #{errors} row(s) errored — see log above") if errors.positive?
  end

  desc 'Rollback: delete every global template created by the legacy migration'
  task rollback_legacy_migration: :environment do
    # Only rows whose provenance key was minted by THIS migration are deleted
    # (external_legacy_id LIKE 'message_template:%'); channel-bound originals,
    # admin-created globals (external_legacy_id IS NULL), and any rows tagged by
    # a future unrelated integration are never touched.
    prefix = MigrateLegacyTemplatesToMessageTemplateJob::LEGACY_KEY_PREFIX
    scope = MessageTemplate.where('external_legacy_id LIKE ?', "#{prefix}:%")
    count = scope.count
    scope.delete_all
    puts "[templates:rollback_legacy_migration] deleted #{count} migrated global templates"
  end
end
