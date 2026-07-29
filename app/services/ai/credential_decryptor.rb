# frozen_string_literal: true

# Decrypts the credential values stored by evo-ai-core-service.
#
# The core encrypts with Fernet using EVO_AI_ENCRYPTION_KEY, the same key the
# processor uses to decrypt. The CRM is a third reader of that value — the key
# is never re-derived or rotated here.
#
# ⚠️ NOT `ENV['ENCRYPTION_KEY']`: that one belongs to InstallationConfig and
# holds a different secret. Reusing it would decrypt nothing and, worse, invite
# someone to "fix" it by overwriting the installation key.
#
# ⚠️ `enforce_ttl = false` is required, not cosmetic. The Ruby gem defaults to a
# 60-second TTL, while the Go side verifies with ttl=0 (no age check). Left on,
# every credential older than a minute would fail to decrypt — and a test using
# a freshly encrypted fixture would never catch it.
class Ai::CredentialDecryptor
  ENCRYPTION_KEY_ENV = 'EVO_AI_ENCRYPTION_KEY'

  class MissingKeyError < StandardError; end

  class << self
    # Returns the plaintext key, or nil when it cannot be decrypted. Callers
    # treat nil as "no usable credential" and fall through the chain.
    def decrypt(ciphertext)
      return nil if ciphertext.blank?

      secret = encryption_key
      if secret.blank?
        Rails.logger.error("Ai::CredentialDecryptor: #{ENCRYPTION_KEY_ENV} is not set")
        return nil
      end

      verifier = Fernet.verifier(secret, ciphertext)
      verifier.enforce_ttl = false

      unless verifier.valid?
        Rails.logger.error('Ai::CredentialDecryptor: credential failed Fernet verification')
        return nil
      end

      verifier.message
    rescue StandardError => e
      Rails.logger.error("Ai::CredentialDecryptor: #{e.class}: #{e.message}")
      nil
    end

    def encryption_key
      ENV.fetch(ENCRYPTION_KEY_ENV, nil)
    end
  end
end
