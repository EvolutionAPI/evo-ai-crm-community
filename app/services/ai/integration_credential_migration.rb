# frozen_string_literal: true

# Imports into the vault the integration secrets that were configured before it
# existed (EVO-2250 story 2.6).
#
# Nothing is deleted: the inline values stay where they are, because the
# consumers still fall back to them until story 2.7 retires that path. What
# changes is where each consumer LOOKS.
#
# ⚠️ Unlike story 1.5, precedence did NOT invert here: a consumer points at one
# credential by id, so the secret on the wire is literally the same one that was
# inline. That makes any divergence suspicious rather than expected — if a row
# reports DIVERGE it is a bug in this migration, not a business rule changing,
# and the gate treats it as a hard failure.
class Ai::IntegrationCredentialMigration
  BOT_NAME_PREFIX = 'Credencial do bot'

  # Bots whose provider sends no credential at all. Registered explicitly so
  # their absence reads as a decision rather than as an oversight.
  PROVIDERS_WITHOUT_CREDENTIAL = %w[webhook_provider].freeze

  class AbortedError < StandardError; end

  def self.call(apply: false, logger: Rails.logger)
    new(apply: apply, logger: logger).call
  end

  def initialize(apply: false, logger: Rails.logger)
    @apply = apply
    @logger = logger
  end

  # Returns the report rows. In apply mode, writes only after every row is OK.
  def call
    ensure_encryption_key!

    plan = build_plan
    rows = build_report(plan)
    emit_report(rows)

    diverging = rows.reject(&:ok?)
    if diverging.any?
      raise AbortedError,
            "migração abortada: #{diverging.size} consumidor(es) mudariam de segredo efetivo (DIVERGE)"
    end

    return rows unless @apply

    write(plan)
    rows
  end

  private

  def ensure_encryption_key!
    return if Ai::CredentialDecryptor.encryption_key.present?

    # Without the key every credential written here is unreadable by the core,
    # the processor and the resolver, and the failure would only surface later.
    raise AbortedError,
          "#{Ai::CredentialDecryptor::ENCRYPTION_KEY_ENV} não está setada; recusando gravar credencial ilegível"
  end

  # What the migration intends to do. Pure: touches nothing.
  def build_plan
    AgentBot.find_each.map { |bot| plan_for_bot(bot) }
  end

  def plan_for_bot(bot)
    return skip(bot, 'provedor não usa credencial') if PROVIDERS_WITHOUT_CREDENTIAL.include?(bot.bot_provider)
    return skip(bot, 'sem chave inline') if bot.api_key.blank?
    return skip(bot, 'já aponta para o cofre') if bot.credential_id.present?

    pair = AgentBots::CredentialResolution.inline_pair(bot.api_key)

    if pair
      # The n8n basic auth is ONE indivisible secret, stored as a composite
      # envelope. The scalar overload of `api_key` is not replicated.
      { bot: bot, plaintext: composite_envelope(pair), format: 'composite', secret_component: pair.last }
    else
      { bot: bot, plaintext: bot.api_key, format: 'scalar', secret_component: bot.api_key }
    end
  end

  def skip(bot, reason)
    { bot: bot, skipped: true, reason: reason }
  end

  def composite_envelope(pair)
    { user: pair.first, password: pair.last }.to_json
  end

  # The gate. For each consumer: does what we would write decrypt back to the
  # value in use today?
  #
  # ⚠️ It is a ROUND-TRIP proof, not a replay of the old precedence. Story 1.5
  # could call the resolver because the old rule lived in Ruby; here the runtime
  # path for tools and MCPs is in Python and cannot be invoked from a rake task.
  # Since precedence did not invert, proving the value survives encryption and
  # decryption intact is what actually catches the failures possible here: a
  # malformed composite, a dedup pointing at the wrong row, a broken key.
  #
  # The bot is the one consumer whose real runtime path IS in Ruby, so it is
  # also checked through AgentBots::CredentialResolution.
  def build_report(plan)
    plan.map do |entry|
      next skipped_row(entry) if entry[:skipped]

      Ai::IntegrationMigrationRow.new(
        subject: "bot #{entry[:bot].id}",
        before_value: effective_before(entry),
        after_value: effective_after(entry),
        origin: "agent_bots.api_key → cofre (#{entry[:format]})"
      )
    end
  end

  def skipped_row(entry)
    Ai::IntegrationMigrationRow.new(
      subject: "bot #{entry[:bot].id}", origin: entry[:reason], skipped: true
    )
  end

  # What the consumer sends today, through its real resolution path.
  def effective_before(entry)
    AgentBots::CredentialResolution.api_key_for(entry[:bot])
  end

  # What it would send after the import: the plaintext we are about to encrypt,
  # decrypted back. For a composite, the comparison is on the pair, because that
  # is what the header is built from.
  def effective_after(entry)
    ciphertext = Ai::CredentialEncryptor.encrypt(entry[:plaintext])
    return nil if ciphertext.blank?

    decrypted = Ai::CredentialDecryptor.decrypt(ciphertext)
    return nil if decrypted.blank?

    entry[:format] == 'composite' ? equivalent_inline_key(decrypted) : decrypted
  end

  # A composite envelope has to rebuild the exact inline form it replaces, so
  # the comparison against `effective_before` is apples to apples.
  def equivalent_inline_key(envelope_json)
    envelope = JSON.parse(envelope_json)
    "#{envelope['user']}:#{envelope['password']}"
  rescue JSON::ParserError
    nil
  end

  def emit_report(rows)
    @logger.info("[Ai::IntegrationCredentialMigration] modo=#{@apply ? 'apply' : 'dry_run'}")
    rows.each { |row| @logger.info("[Ai::IntegrationCredentialMigration] #{row.to_line}") }
    @logger.info(
      "[Ai::IntegrationCredentialMigration] #{rows.count(&:ok?)}/#{rows.size} OK " \
      "(#{rows.count(&:skipped?)} pulado(s))"
    )
  end

  def write(plan)
    plan.reject { |entry| entry[:skipped] }.each { |entry| import_bot(entry) }
  end

  def import_bot(entry)
    credential_id = find_or_create_credential(entry)
    return if credential_id.blank?

    # `update_all` on the relation, not `update` on the record: AgentBot is a
    # normal model here, but the same call shape is used for the core-owned
    # tables, whose models are read-only by design.
    AgentBot.where(id: entry[:bot].id, credential_id: nil).update_all( # rubocop:disable Rails/SkipsModelValidations
      credential_id: credential_id, updated_at: Time.current
    )
  end

  # Deduplication is by VALUE: the same secret in N consumers becomes ONE
  # credential with N references.
  #
  # That is why `imported_from` is derived from the SECRET and not from the
  # consumer. Keying it on the consumer would make the second consumer sharing a
  # secret look "not yet imported" and create a duplicate, which is exactly what
  # the idempotency requirement forbids.
  def find_or_create_credential(entry)
    source = import_source(entry[:plaintext])

    existing = Ai::IntegrationCredential.find_by(imported_from: source)
    return existing.id if existing

    ciphertext = Ai::CredentialEncryptor.encrypt(entry[:plaintext])
    raise AbortedError, "falha ao cifrar a credencial de #{entry[:bot].id}" if ciphertext.blank?

    insert_credential(entry, source, ciphertext)
  end

  def insert_credential(entry, source, ciphertext)
    Ai::IntegrationCredential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: unique_name("#{BOT_NAME_PREFIX} #{entry[:bot].bot_provider.to_s.delete_suffix('_provider')}"),
        provider: entry[:bot].bot_provider.to_s.delete_suffix('_provider'),
        kind: Ai::IntegrationCredential::KIND_STATIC,
        value: ciphertext,
        value_format: entry[:format],
        # The hint comes from the SECRET component: hinting on the envelope
        # would render JSON syntax, and hinting on the user would mask the
        # public half of the pair.
        value_hint: Ai::CredentialEncryptor.key_hint(entry[:secret_component]),
        scope: Ai::IntegrationCredential::SCOPE_ACCOUNT,
        is_active: true,
        imported_from: source,
        created_at: Time.current,
        updated_at: Time.current
      }]
    )
    Ai::IntegrationCredential.find_by(imported_from: source)&.id
  end

  # Deterministic from the secret, so a re-run finds the row it created and two
  # consumers sharing a secret land on the same one. The digest never exposes
  # the secret itself.
  def import_source(plaintext)
    "integration:sha256:#{Digest::SHA256.hexdigest(plaintext)}"
  end

  # The unique index is (scope, name), so a collision inside the same scope is a
  # database error rather than a cosmetic detail.
  def unique_name(base)
    scope = Ai::IntegrationCredential::SCOPE_ACCOUNT
    return base unless Ai::IntegrationCredential.exists?(scope: scope, name: base)

    suffix = 2
    suffix += 1 while Ai::IntegrationCredential.exists?(scope: scope, name: "#{base} (#{suffix})")
    "#{base} (#{suffix})"
  end
end
