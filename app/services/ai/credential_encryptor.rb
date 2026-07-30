# frozen_string_literal: true

# Encrypts a credential so evo-ai-core-service and the processor can read it.
#
# Only the migrations write credentials from Ruby: everything else goes through
# the core's endpoint, which encrypts server-side but sits behind a user-bearer
# check a rake task does not have. Same Fernet key as the Go side, and
# credential_encryptor_spec proves a token from here survives its decrypt.
class Ai::CredentialEncryptor
  KEY_HINT_LENGTH = 4

  class << self
    # Returns the ciphertext, or nil when the key is missing. Callers treat nil
    # as "cannot write" and must abort rather than store something unreadable.
    def encrypt(plaintext)
      return nil if plaintext.blank?

      secret = Ai::CredentialDecryptor.encryption_key
      if secret.blank?
        Rails.logger.error("Ai::CredentialEncryptor: #{Ai::CredentialDecryptor::ENCRYPTION_KEY_ENV} is not set")
        return nil
      end

      Fernet.generate(secret, plaintext)
    rescue StandardError => e
      Rails.logger.error("Ai::CredentialEncryptor: #{e.class}: #{e.message}")
      nil
    end

    # Mirrors DeriveKeyHint in the Go model: the last characters of the plaintext,
    # so the screen renders a mask without the key ever reaching the browser.
    def key_hint(plaintext)
      return '' if plaintext.blank?

      characters = plaintext.chars
      return plaintext if characters.length <= KEY_HINT_LENGTH

      characters.last(KEY_HINT_LENGTH).join
    end
  end
end
