# frozen_string_literal: true

# Answers whether this installation has moved to the credential registry.
#
# Story 1.6 removes the legacy fallback, and this guard is what keeps that
# removal from silently switching off AI. An installation that never ran the 1.5
# task still has its key only in the old sources: cutting the fallback there
# would make the resolver return nothing and every feature behave as
# "not configured", with no error pointing at the cause.
#
# Migrated means either of:
#   - the 1.5 task ran (a credential carries `imported_from`), or
#   - there is nothing to migrate (no key in any legacy source), which is the
#     case for a fresh install that only ever used the new screen.
class Ai::MigrationState
  class << self
    # `legacy_hook` is the caller's own openai Hook, when it has one. Without it
    # a consumer holding a hook the global lookup cannot see would be judged
    # "migrated" and lose the very key it was about to use.
    def migrated?(legacy_hook: nil)
      imported_credentials? || legacy_sources_empty?(legacy_hook: legacy_hook)
    end

    # The fallback stays alive exactly while the guard says we are not migrated.
    def legacy_fallback_active?(legacy_hook: nil)
      !migrated?(legacy_hook: legacy_hook)
    end

    def imported_credentials?
      Ai::Credential.where.not(imported_from: nil).exists?
    rescue StandardError => e
      # A missing table or a DB hiccup must not be read as "migrated": that
      # would remove the fallback on a broken install.
      Rails.logger.error("Ai::MigrationState: #{e.class}: #{e.message}")
      false
    end

    def legacy_sources_empty?(legacy_hook: nil)
      GlobalConfigService.load('OPENAI_API_SECRET', nil).blank? &&
        legacy_hook_key(legacy_hook).blank?
    rescue StandardError => e
      Rails.logger.error("Ai::MigrationState: #{e.class}: #{e.message}")
      false
    end

    # Logged once per resolution that actually needed the fallback, so the
    # operator learns what to run instead of guessing.
    def warn_pending_migration
      Rails.logger.warn(
        '[Ai::MigrationState] usando credencial de fonte legada: rode ' \
        '`bin/rails ai_credentials:migrate_dry_run` e depois `ai_credentials:migrate` ' \
        'para migrar as credenciais para o registro'
      )
    end

    private

    def legacy_hook_key(legacy_hook = nil)
      hook = legacy_hook || Integrations::Hook.find_by(app_id: 'openai')
      hook&.settings&.dig('api_key').presence
    end
  end
end
