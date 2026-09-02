# frozen_string_literal: true

# Answers whether this installation has moved to the credential registry, which
# is what keeps the legacy fallback from being cut on an install that never
# migrated — there, AI would go silently "not configured".
#
# Migrated means the task ran (a credential carries `imported_from`) OR there is
# no key in any legacy source, the case for a fresh install.
class Ai::MigrationState
  class << self
    # `legacy_hook` is the caller's own openai Hook: without it, a consumer
    # holding a hook the global lookup cannot see is judged "migrated" and loses
    # the very key it was about to use.
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
