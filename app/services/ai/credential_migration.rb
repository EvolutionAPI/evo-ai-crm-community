# frozen_string_literal: true

# Imports the credentials configured before the registry existed.
#
# ⚠️ THE PRECEDENCE INVERTS: the global key used to win over the account hook,
# and now the account credential wins. Importing "each source to its own level"
# would therefore SWAP the key in use, so where both exist the ACCOUNT
# credential is created with the GLOBAL value. The hook key lands inactive
# rather than being lost.
#
# Nothing is deleted: the legacy fallback still reads those sources.
# rubocop:disable Metrics/ClassLength -- splitting the class would separate the
# analytic projection from the rules it projects.
class Ai::CredentialMigration
  # ⚠️ Idempotency keys, and they go into `imported_from VARCHAR(64)`. Keep every
  # source under 64 characters: an overflow mid-import leaves a PARTIAL write
  # that flips MigrationState to "migrated" and kills the fallback for everyone.
  INSTALLATION_SOURCE = 'installation_configs:OPENAI_API_SECRET'
  HOOK_SOURCE_PREFIX = 'hook:openai:'
  HOOK_ORIGINAL_SUFFIX = ':orig'

  INSTALLATION_NAME = 'Padrão da instalação (migrado)'
  ACCOUNT_NAME = 'Credencial da conta (migrado)'
  INACTIVE_HOOK_NAME = 'Chave do hook OpenAI (migrado, inativa)'

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
            "migration aborted: #{diverging.size} account(s) would change effective credential"
    end

    return rows unless @apply

    write(plan)
    rows
  end

  private

  def ensure_encryption_key!
    return if Ai::CredentialDecryptor.encryption_key.present?

    # Without the key every credential written here is unreadable by the core,
    # the processor and the resolver — and the failure would only surface later,
    # inside a job.
    raise AbortedError,
          "#{Ai::CredentialDecryptor::ENCRYPTION_KEY_ENV} is not set; refusing to write unreadable credentials"
  end

  # What the migration intends to create. Pure: touches nothing.
  def build_plan
    {
      global_key: GlobalConfigService.load('OPENAI_API_SECRET', nil).presence,
      global_api_url: GlobalConfigService.load('OPENAI_API_URL', nil).presence,
      hooks: openai_hooks
    }
  end

  def openai_hooks
    Integrations::Hook.where(app_id: 'openai').filter_map do |hook|
      key = hook.settings&.dig('api_key').presence
      next if key.blank?

      { hook: hook, key: key }
    end
  end

  # The effective credential today, and what it would be after the import.
  # BEFORE comes from the resolver itself, whose legacy link IS the old
  # precedence: reimplementing it here would drift from the real rule.
  def build_report(plan)
    rows = []

    # Only meaningful with a global key: without one, `resolve_key` still
    # reaches the account hook through the legacy link, and comparing that
    # against an installation-level plan reports a phantom divergence.
    if plan[:global_key].present?
      rows << Ai::CredentialMigrationRow.new(
        subject: 'instalação',
        before_key: Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist),
        after_key: effective_after(plan, hook_key: nil),
        origin: installation_origin(plan)
      )
    end

    plan[:hooks].each do |entry|
      before = Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist, legacy_hook: entry[:hook])
      rows << Ai::CredentialMigrationRow.new(
        subject: "hook #{entry[:hook].id}",
        before_key: before,
        after_key: effective_after(plan, hook_key: entry[:key]),
        origin: hook_origin(plan, entry[:key])
      )
    end

    rows
  end

  # Resolution AFTER the import, computed analytically — never by writing and
  # rolling back, because the report must run without side effects.
  #
  # ⚠️ It must project through the SAME precedence the resolver uses. Answering
  # with the current resolution would make the gate unfalsifiable, and the
  # import inserts an `account` row that outranks an installation credential a
  # human already registered.
  def effective_after(plan, hook_key:)
    imported = plan[:global_key] || hook_key

    # What the import will place at each scope. The account link carries the
    # global value when both exist (that is the promotion this class exists for).
    projected = {
      Ai::Credential::SCOPE_INSTALLATION => plan[:global_key],
      Ai::Credential::SCOPE_ACCOUNT => (imported if hook_key.present? || plan[:global_key].present?)
    }

    # Most specific link wins, exactly like Ai::ScopeChain: an already-registered
    # credential only survives where the import puts nothing.
    Ai::ScopeChain.chain.reverse_each do |scope|
      projected_key = projected[scope.to_s]
      return projected_key if projected_key.present?

      existing = existing_key_at(scope.to_s)
      return existing if existing.present?
    end

    nil
  end

  # The plaintext of the credential already stored at a scope, or nil.
  def existing_key_at(scope)
    credential = Ai::Credential.active.for_scope(scope).order(created_at: :asc).first
    return nil unless credential

    Ai::CredentialDecryptor.decrypt(credential.key)
  end

  def registry_already_populated?
    Ai::Credential.active.exists?
  end

  def existing_registry_key
    Ai::CredentialResolver.resolve_key(for_consumer: :inbox_assist)
  end

  def installation_origin(plan)
    return 'nada a migrar' if plan[:global_key].blank?

    'installation_configs → escopo instalação'
  end

  def hook_origin(plan, hook_key)
    return 'nada a migrar' if hook_key.blank? && plan[:global_key].blank?

    if plan[:global_key].present? && plan[:global_key] != hook_key
      'chave GLOBAL promovida para o escopo conta (hook importado inativo)'
    else
      'hook → escopo conta'
    end
  end

  def emit_report(rows)
    @logger.info("[Ai::CredentialMigration] modo=#{@apply ? 'apply' : 'dry_run'}")
    rows.each { |row| @logger.info("[Ai::CredentialMigration] #{row.to_line}") }
    @logger.info("[Ai::CredentialMigration] #{rows.count(&:ok?)}/#{rows.size} OK")
  end

  # One transaction for the whole import.
  #
  # Without it, a failure midway (a too-long source, an encryption error, a
  # unique-index race) leaves earlier rows committed. That partial state flips
  # BOTH `registry_already_populated?` and `MigrationState.imported_credentials?`
  # to true, so the next run short-circuits its own gate and the legacy fallback
  # switches off globally — including for hooks that were never imported.
  def write(plan)
    ActiveRecord::Base.transaction do
      import_installation(plan)
      plan[:hooks].each { |entry| import_hook(plan, entry) }
    end
  end

  def import_installation(plan)
    return if plan[:global_key].blank?

    create_credential(
      name: INSTALLATION_NAME,
      plaintext: plan[:global_key],
      scope: Ai::Credential::SCOPE_INSTALLATION,
      provider: provider_for(plan[:global_api_url]),
      base_url: custom_base_url(plan[:global_api_url]),
      source: INSTALLATION_SOURCE
    )
  end

  def import_hook(plan, entry)
    hook_key = entry[:key]
    promoted = plan[:global_key].present? && plan[:global_key] != hook_key

    # The account credential carries the value that wins TODAY.
    create_credential(
      name: ACCOUNT_NAME,
      plaintext: promoted ? plan[:global_key] : hook_key,
      scope: Ai::Credential::SCOPE_ACCOUNT,
      provider: provider_for(plan[:global_api_url]),
      base_url: custom_base_url(plan[:global_api_url]),
      source: "#{HOOK_SOURCE_PREFIX}#{entry[:hook].id}"
    )

    return unless promoted

    # The hook key is not discarded: it lands inactive so a human can promote it.
    create_credential(
      name: INACTIVE_HOOK_NAME,
      plaintext: hook_key,
      scope: Ai::Credential::SCOPE_ACCOUNT,
      provider: 'openai',
      source: "#{HOOK_SOURCE_PREFIX}#{entry[:hook].id}#{HOOK_ORIGINAL_SUFFIX}",
      active: false
    )
  end

  # Only a CUSTOM endpoint is stored: NULL already means "the provider default",
  # which is what every credential registered before this column meant. Stamping
  # the public URL on every install would be noise with no information in it.
  def custom_base_url(api_url)
    return nil if api_url.blank?
    return nil if api_url.include?('api.openai.com')

    api_url
  end

  # A custom base URL means the provider is not stock OpenAI.
  def provider_for(api_url)
    return 'openai' if api_url.blank? || api_url.include?('api.openai.com')

    'custom_openai_compatible'
  end

  # Keyword-arg bundle for a credential the migration intends to create.
  Planned = Struct.new(:name, :plaintext, :scope, :provider, :source, :active, :base_url, keyword_init: true)

  def create_credential(**attrs)
    planned = Planned.new(active: true, **attrs)

    # imported_from is the idempotency key, not the name: a human may rename or
    # disable an imported credential, and a re-run must respect that.
    return if Ai::Credential.exists?(imported_from: planned.source)

    ciphertext = Ai::CredentialEncryptor.encrypt(planned.plaintext)
    raise AbortedError, "failed to encrypt credential for #{planned.source}" if ciphertext.blank?

    Ai::Credential.insert_all!([row_for(planned, ciphertext)]) # rubocop:disable Rails/SkipsModelValidations
  end

  def row_for(planned, ciphertext)
    {
      name: unique_name(planned.name),
      provider: planned.provider,
      key: ciphertext,
      key_hint: Ai::CredentialEncryptor.key_hint(planned.plaintext),
      scope: planned.scope,
      base_url: planned.base_url,
      is_active: planned.active,
      imported_from: planned.source,
      created_at: Time.current,
      updated_at: Time.current
    }
  end

  # `name` carries a UNIQUE index, so a collision is a database error rather
  # than a cosmetic detail.
  def unique_name(base)
    return base unless Ai::Credential.exists?(name: base)

    suffix = 2
    suffix += 1 while Ai::Credential.exists?(name: "#{base} (#{suffix})")
    "#{base} (#{suffix})"
  end
end
# rubocop:enable Metrics/ClassLength
