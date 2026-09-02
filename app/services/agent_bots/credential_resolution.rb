# frozen_string_literal: true

# Resolves the secret a channel bot sends to its provider: the vault when the
# bot references one, the inline `api_key` while the fallback lives.
#
# BY REFERENCE only — a bot configured with one credential must never fall
# through to a different one, so the provider-default path is not used here.
#
# ⚠️ `agent_bots` has no `account_id`, so the scope chain has nothing to resolve
# against. A known gap of the table.
module AgentBots::CredentialResolution
  module_function

  # Returns the plaintext key in effect, or nil when neither the vault nor the
  # inline value offers one. Never raises: a bot with no usable credential is an
  # expected state, handled by the caller.
  def api_key_for(bot)
    from_vault = vault_value(bot)
    return from_vault if from_vault.present?

    inline_key(bot)
  end

  # Returns the [user, password] pair for n8n basic auth, or nil. The storage
  # shape differs — colon-encoded inline, a composite envelope in the vault —
  # but the Authorization header on the wire must be byte-identical.
  def basic_auth_for(bot)
    from_vault = vault_value(bot)
    return composite_pair(from_vault) if from_vault.present?

    inline_pair(inline_key(bot))
  end

  # The retirement gate: the inline column stops being READ once the migration
  # has run, though the data stays. Fail-closed — any doubt, including a database
  # error, keeps the fallback alive rather than waking an installation with no
  # integrations and no error pointing at the cause.
  #
  # Column first, guard second: the guard counts pending secrets across two
  # tables, and asking it before there is anything to gate charges every dispatch.
  def inline_key(bot)
    inline = bot.api_key.presence
    return nil if inline.nil?

    Ai::IntegrationMigrationState.migrated? ? nil : inline
  end

  def vault_value(bot)
    return nil if bot.credential_id.blank?

    resolution = Ai::IntegrationCredentialResolver.resolve_value(credential_id: bot.credential_id)
    return nil unless resolution.present_value?

    resolution.value
  rescue StandardError => e
    # A vault outage degrades to the inline value instead of taking the bot down.
    Rails.logger.error("AgentBots::CredentialResolution: #{e.class}: #{e.message}")
    nil
  end

  def composite_pair(value)
    envelope = JSON.parse(value)

    # ⚠️ A scalar secret parses FINE: `JSON.parse("12345")` returns an Integer,
    # and indexing it raises TypeError outside the rescue below. A non-Hash is
    # not an envelope — it is what the colon convention handles.
    return inline_pair(value) unless envelope.is_a?(Hash)

    user = envelope['user'].presence
    password = envelope['password'].presence
    return nil unless user && password

    [user, password]
  rescue JSON::ParserError
    # Not JSON at all: same fallback, for a credential holding "user:pass".
    inline_pair(value)
  end

  def inline_pair(api_key)
    return nil if api_key.blank? || api_key.exclude?(':')

    user, password = api_key.split(':', 2)
    return nil if user.blank? || password.blank?

    [user, password]
  end
end
