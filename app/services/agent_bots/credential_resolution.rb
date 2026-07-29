# frozen_string_literal: true

# Resolves the secret a channel bot sends to its provider.
#
# The bot may point at the integration credential vault (EVO-2250 story 2.4);
# the inline `api_key` stays the fallback until story 2.7 retires it, so no
# installation has to migrate for this to work.
#
# Resolution is BY REFERENCE only. A bot configured with one credential must
# never fall through to a different one: `Ai::IntegrationCredentialResolver`
# owns that rule, and the provider-default path is deliberately not used here.
#
# ⚠️ `agent_bots` has no `account_id`, so there is no account link for the scope
# chain to resolve against. That is a known gap of the table, not of this story.
module AgentBots::CredentialResolution
  module_function

  # Returns the plaintext key in effect, or nil when neither the vault nor the
  # inline value offers one. Never raises: a bot with no usable credential is an
  # expected state, handled by the caller.
  def api_key_for(bot)
    from_vault = vault_value(bot)
    return from_vault if from_vault.present?

    bot.api_key.presence
  end

  # Returns the [user, password] pair for n8n basic auth, or nil.
  #
  # The stored shape changed but the wire format did not: today the pair is
  # encoded inside `api_key` by the presence of a colon, and the vault keeps it
  # structured in a composite envelope. What has to stay identical is the byte
  # that goes out in the Authorization header.
  def basic_auth_for(bot)
    from_vault = vault_value(bot)
    return composite_pair(from_vault) if from_vault.present?

    inline_pair(bot.api_key)
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
    user = envelope['user'].presence
    password = envelope['password'].presence
    return nil unless user && password

    [user, password]
  rescue JSON::ParserError
    # Not an envelope: fall back to the colon convention, so a scalar credential
    # holding "user:pass" keeps working.
    inline_pair(value)
  end

  def inline_pair(api_key)
    return nil if api_key.blank? || api_key.exclude?(':')

    user, password = api_key.split(':', 2)
    return nil if user.blank? || password.blank?

    [user, password]
  end
end
