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
# rubocop:disable Metrics/ClassLength -- one plan_for_* per store is the shape
# the story asks for; splitting it would hide the per-store rules the reviewer
# has to check side by side.
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

  # Header names that are recognisably authentication. The heuristic errs on the
  # side of NOT migrating: importing a header that is not a secret breaks the
  # call, while leaving a secret behind only delays the gain. The two mistakes
  # do not cost the same.
  AUTH_HEADER_NAMES = %w[authorization x-api-key api-key apikey x-auth-token].freeze

  # Where each static provider keeps its secret inside `config`. Only the secret
  # travels: apiUrl, webhookUrl, space_id and friends are the address, and
  # keeping them out is what lets one credential serve several consumers.
  INTEGRATION_SECRET_FIELDS = {
    'dify' => %w[apiKey],
    'flowise' => %w[apiKey],
    'openai' => %w[apiKey],
    'elevenlabs' => %w[apiKey],
    'knowledge_nexus' => %w[nexus_api_key apiKey],
    'n8n' => %w[basicAuthUser basicAuthPass]
  }.freeze

  # What the migration intends to do. Pure: touches nothing.
  #
  # Each store is scanned defensively: the core owns those tables and an
  # installation may be running a core older than the migration that created
  # them. A missing table means "nothing to migrate here", not a crash that
  # would take the whole migration down with it.
  def build_plan
    scan(AgentBot) { |r| r == :relation ? AgentBot.all : [plan_for_bot(r)] } +
      scan(Ai::CustomTool) { |r| r == :relation ? Ai::CustomTool.active : plan_for_headers(r, :custom_tool) } +
      scan(Ai::CustomMcpServer) { |r| r == :relation ? Ai::CustomMcpServer.active : plan_for_headers(r, :custom_mcp_server) } +
      scan(Ai::AgentIntegration) { |r| r == :relation ? Ai::AgentIntegration.all : [plan_for_integration(r)] }
  end

  # The table is checked BEFORE querying, not rescued after: a failed statement
  # aborts the surrounding transaction in Postgres, so catching the error would
  # leave every later query failing too.
  def scan(model)
    unless table_available?(model)
      @logger.warn("[Ai::IntegrationCredentialMigration] store #{model.table_name} ausente, pulado")
      return []
    end

    # rubocop:disable Style/ExplicitBlockArgument -- the block serves two roles
    # (build the relation, then map each record), so an explicit &block would
    # not simplify it.
    yield(:relation).find_each.flat_map { |record| yield(record) }
    # rubocop:enable Style/ExplicitBlockArgument
  end

  # The core owns these tables, and an installation may run a core older than
  # the migration that created them. A missing table means "nothing to migrate
  # here", not a crash that takes the whole migration down.
  def table_available?(model)
    model.connection.table_exists?(model.table_name)
  end

  # Tools and MCP servers keep a free-form header map, so the reference is a MAP
  # (header name -> credential id): two auth headers are two credentials.
  def plan_for_headers(record, kind)
    headers = parse_json(record.headers)
    existing_refs = parse_json(record.credential_refs)

    auth_headers = headers.select { |name, value| auth_header?(name) && value.present? }
    return [skip_record(record, kind, 'nenhum header de autenticação reconhecido')] if auth_headers.empty?

    auth_headers.filter_map do |name, value|
      next if existing_refs[name].present?

      { record: record, kind: kind, header: name, plaintext: value, format: 'scalar', secret_component: value }
    end.presence || [skip_record(record, kind, 'headers já apontam para o cofre')]
  end

  def plan_for_integration(integration)
    provider = integration.provider
    fields = INTEGRATION_SECRET_FIELDS[provider]

    # ⚠️ Everything outside the static allowlist is a deliberate skip: OAuth
    # connection rows and their `<provider>_credentials` satellites hold tokens
    # the vault must never own (story 2.5 lists them by reference instead), and
    # typebot authenticates with nothing at all.
    return skip_record(integration, :agent_integration, "provedor #{provider} não guarda segredo estático") if fields.blank?

    config = parse_json(integration.config)
    return skip_record(integration, :agent_integration, 'já aponta para o cofre') if config['credential_id'].present?

    build_integration_entry(integration, provider, fields, config)
  end

  def build_integration_entry(integration, provider, fields, config)
    if provider == 'n8n'
      user = config['basicAuthUser'].presence
      password = config['basicAuthPass'].presence
      return skip_record(integration, :agent_integration, 'sem par de basic auth') if user.blank? || password.blank?

      return {
        record: integration, kind: :agent_integration,
        plaintext: { user: user, password: password }.to_json,
        format: 'composite', secret_component: password, provider: provider
      }
    end

    value = fields.filter_map { |field| config[field].presence }.first
    return skip_record(integration, :agent_integration, 'sem segredo no config') if value.blank?

    {
      record: integration, kind: :agent_integration, plaintext: value,
      format: 'scalar', secret_component: value, provider: provider
    }
  end

  def auth_header?(name)
    AUTH_HEADER_NAMES.include?(name.to_s.downcase)
  end

  def parse_json(value)
    return value if value.is_a?(Hash)
    return {} if value.blank?

    JSON.parse(value)
  rescue JSON::ParserError
    {}
  end

  def skip_record(record, kind, reason)
    { record: record, kind: kind, skipped: true, reason: reason }
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
        subject: subject_for(entry),
        before_value: effective_before(entry),
        after_value: effective_after(entry),
        origin: "#{origin_for(entry)} → cofre (#{entry[:format]})"
      )
    end
  end

  def skipped_row(entry)
    Ai::IntegrationMigrationRow.new(subject: subject_for(entry), origin: entry[:reason], skipped: true)
  end

  def subject_for(entry)
    return "bot #{entry[:bot].id}" if entry[:bot]

    header = entry[:header] ? " [#{entry[:header]}]" : ''
    "#{entry[:kind]} #{entry[:record].id}#{header}"
  end

  def origin_for(entry)
    return 'agent_bots.api_key' if entry[:bot]
    return "#{entry[:kind]}.headers" if entry[:header]

    "#{entry[:kind]}.config"
  end

  # What the consumer sends today.
  #
  # ⚠️ It must NOT go through `AgentBots::CredentialResolution`: since story 2.7
  # that resolver honours the retirement guard, and this migration is precisely
  # the thing that READS the legacy source in order to import it. Asking the
  # gated resolver would report "no secret" for every bot on the second run and
  # abort with a phantom DIVERGE.
  #
  # The vault value wins when the bot already references one (a re-run must
  # compare against what is in effect), and the inline column is read directly
  # otherwise.
  def effective_before(entry)
    if entry[:bot]
      from_vault = AgentBots::CredentialResolution.vault_value(entry[:bot])
      return from_vault.presence || entry[:bot].api_key.presence
    end

    # For the stores whose runtime path lives in Python, the inline value IS
    # what goes out today, so it is the honest left-hand side of the gate.
    entry[:format] == 'composite' ? equivalent_inline_key(entry[:plaintext]) : entry[:plaintext]
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
    plan.reject { |entry| entry[:skipped] }.each do |entry|
      entry[:bot] ? import_bot(entry) : import_record(entry)
    end
  end

  # Tools, MCP servers and agent integrations. The reference is written back
  # into the table the CORE owns, so it goes through `update_all` on the
  # relation: those models are read-only by design, and an instance `update`
  # would raise.
  def import_record(entry)
    credential_id = find_or_create_credential(entry)
    return if credential_id.blank?

    entry[:header] ? link_header_ref(entry, credential_id) : link_config_ref(entry, credential_id)
  end

  def link_header_ref(entry, credential_id)
    record = entry[:record].reload
    refs = parse_json(record.credential_refs)
    # A human may have pointed this header elsewhere after the first run.
    return if refs[entry[:header]].present?

    refs[entry[:header]] = credential_id
    record.class.where(id: record.id).update_all( # rubocop:disable Rails/SkipsModelValidations
      credential_refs: refs, updated_at: Time.current
    )
  end

  def link_config_ref(entry, credential_id)
    record = entry[:record].reload
    config = parse_json(record.config)
    return if config['credential_id'].present?

    config['credential_id'] = credential_id
    record.class.where(id: record.id).update_all( # rubocop:disable Rails/SkipsModelValidations
      config: config, updated_at: Time.current
    )
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
    if existing
      # The digest match proves the secret was imported ONCE — not that the row
      # still holds it. A human may have rotated the imported credential since;
      # linking a new consumer to it would silently swap the secret on the
      # wire, which is the exact change the ANTES=DEPOIS gate exists to forbid
      # (found in the adversarial review of 2026-07-29). Fail loud instead.
      stored = Ai::CredentialDecryptor.decrypt(existing.value)
      unless stored == entry[:plaintext]
        raise AbortedError,
              "credencial importada #{existing.id} foi alterada depois da importação e não " \
              "corresponde mais ao segredo de #{subject_for(entry)}; ligue o consumidor manualmente"
      end

      return existing.id
    end

    ciphertext = Ai::CredentialEncryptor.encrypt(entry[:plaintext])
    raise AbortedError, "falha ao cifrar a credencial de #{subject_for(entry)}" if ciphertext.blank?

    insert_credential(entry, source, ciphertext)
  end

  # Deterministic per origin, so a re-run never renames a row.
  def credential_name_for(entry)
    return "#{BOT_NAME_PREFIX} #{credential_provider_for(entry)}" if entry[:bot]
    return "Header #{entry[:header]} (#{entry[:kind]})" if entry[:header]

    "Credencial #{entry[:provider]}"
  end

  def credential_provider_for(entry)
    return entry[:bot].bot_provider.to_s.delete_suffix('_provider') if entry[:bot]
    return entry[:provider] if entry[:provider]

    entry[:kind].to_s
  end

  def insert_credential(entry, source, ciphertext)
    Ai::IntegrationCredential.insert_all!( # rubocop:disable Rails/SkipsModelValidations
      [{
        name: unique_name(credential_name_for(entry)),
        provider: credential_provider_for(entry),
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
# rubocop:enable Metrics/ClassLength
