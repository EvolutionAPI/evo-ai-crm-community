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
    # EVERY store the 2.6 migration touches, not just bots.
    #
    # ⚠️ Looking only at AgentBot was a fail-open: an installation whose inline
    # secret lives in a Dify integration and has no bots answered "migrated",
    # and retiring the inline read there leaves the agent authenticating with
    # nothing (review of 2026-07-29, finding 10).
    def legacy_sources_empty?
      pending_bots.zero? && pending_integrations.zero?
    rescue StandardError => e
      # A database hiccup must not read as "migrated": that would remove the
      # fallback on a broken install.
      Rails.logger.error("Ai::IntegrationMigrationState: #{e.class}: #{e.message}")
      false
    end

    def pending_bots
      AgentBot.where(credential_id: nil)
              .where.not(api_key: [nil, ''])
              .count
    end

    # An integration still holding a static secret inline, with no vault
    # reference replacing it. Tools and MCP servers live in tables the core owns
    # and are counted by the Go endpoint; here we cover what Rails can see.
    def pending_integrations
      return 0 unless Ai::AgentIntegration.table_exists?

      Ai::AgentIntegration
        .static_providers
        .where("config ->> 'credential_id' IS NULL")
        .where("COALESCE(config ->> 'apiKey', config ->> 'nexus_api_key', config ->> 'basicAuthPass', '') <> ''")
        .count
    end
  end
end
