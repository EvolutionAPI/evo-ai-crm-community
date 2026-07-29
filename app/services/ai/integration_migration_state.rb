# frozen_string_literal: true

# Answers whether this installation has moved its integration secrets into the
# vault (EVO-2250 story 2.6).
#
# Story 2.7 removes the inline fallback, and this guard is what keeps that
# removal from silently switching integrations off. An installation that never
# ran the 2.6 task still has its secrets only in the old stores: cutting the
# fallback there would leave every bot, tool and MCP resolving to nothing, with
# no error pointing at the cause.
#
# Migrated means either of:
#   - the task ran (a credential carries `imported_from`), or
#   - there is nothing to migrate, which is the case for a fresh install that
#     only ever used the vault screen.
class Ai::IntegrationMigrationState
  class << self
    def migrated?
      imported_credentials? || legacy_sources_empty?
    end

    # The fallback stays alive exactly while the guard says we are not migrated.
    def legacy_fallback_active?
      !migrated?
    end

    def imported_credentials?
      Ai::IntegrationCredential.where.not(imported_from: nil).exists?
    rescue StandardError => e
      # A missing table or a database hiccup must not read as "migrated": that
      # would remove the fallback on a broken install.
      Rails.logger.error("Ai::IntegrationMigrationState: #{e.class}: #{e.message}")
      false
    end

    # A bot still holding an inline key that no vault reference replaces is a
    # legacy secret waiting to be migrated.
    def legacy_sources_empty?
      !AgentBot.where(credential_id: nil)
               .where.not(api_key: [nil, ''])
               .exists?
    rescue StandardError => e
      Rails.logger.error("Ai::IntegrationMigrationState: #{e.class}: #{e.message}")
      false
    end
  end
end
