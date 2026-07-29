# frozen_string_literal: true

# Imports the credentials configured before the registry existed.
#
# ⚠️ THE PRECEDENCE INVERTS. Before: the global `OPENAI_API_SECRET` wins and the
# account hook is the fallback. After: the account credential wins and the
# installation one is the default. So importing "each source to its own level"
# would SWAP the key in use — the account would start using the hook key that is
# ignored today.
#
# The fix: where both exist, the ACCOUNT credential is created with the GLOBAL
# value, so the resolver keeps returning the same key through the new path. The
# hook key is not lost: it is imported inactive, visible, for a human to decide.
#
# Nothing is deleted here. `OPENAI_API_SECRET` and the hook settings stay put —
# removing them is story 1.6, and the legacy fallback still reads them.
class Ai::CredentialMigration
  INSTALLATION_SOURCE = 'installation_configs:OPENAI_API_SECRET'
  HOOK_SOURCE_PREFIX = 'integrations_hooks:openai:'

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
  #
  # BEFORE comes from the resolver itself: on an unmigrated install the registry
  # is empty, so it falls through to the legacy link — which IS the old
  # precedence. Reimplementing it here would risk drifting from the real rule.
  def build_report(plan)
    rows = []

    # Only meaningful when there IS a global key: with none, `resolve_key`
    # without a hook still reaches the account hook through the legacy link, and
    # comparing that against an installation-level plan would report a phantom
    # divergence for a level that has nothing to migrate.
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
  def effective_after(plan, hook_key:)
    return existing_registry_key if registry_already_populated?

    # The account link is created with the global value when both exist, so the
    # winner is unchanged. Otherwise whichever single source exists wins.
    plan[:global_key] || hook_key
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

  def write(plan)
    import_installation(plan)
    plan[:hooks].each { |entry| import_hook(plan, entry) }
  end

  def import_installation(plan)
    return if plan[:global_key].blank?

    create_credential(
      name: INSTALLATION_NAME,
      plaintext: plan[:global_key],
      scope: Ai::Credential::SCOPE_INSTALLATION,
      provider: provider_for(plan[:global_api_url]),
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
      source: "#{HOOK_SOURCE_PREFIX}#{entry[:hook].id}"
    )

    return unless promoted

    # The hook key is not discarded: it lands inactive so a human can promote it.
    create_credential(
      name: INACTIVE_HOOK_NAME,
      plaintext: hook_key,
      scope: Ai::Credential::SCOPE_ACCOUNT,
      provider: 'openai',
      source: "#{HOOK_SOURCE_PREFIX}#{entry[:hook].id}:original",
      active: false
    )
  end

  # A custom base URL means the provider is not stock OpenAI.
  def provider_for(api_url)
    return 'openai' if api_url.blank? || api_url.include?('api.openai.com')

    'custom_openai_compatible'
  end

  # Keyword-arg bundle for a credential the migration intends to create.
  Planned = Struct.new(:name, :plaintext, :scope, :provider, :source, :active, keyword_init: true)

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
