class GlobalConfigService
  def self.load(config_key, default_value)
    # Priority 1: Check database first (user-configured values take precedence)
    config = GlobalConfig.get(config_key)[config_key]
    # Use !nil? instead of present? to allow false boolean values
    return config unless config.nil?

    # Priority 2: Check environment variables as fallback
    env_value = ENV.fetch(config_key, nil)
    return env_value if env_value.present?

    # Priority 3: Return default value if not found anywhere
    default_value
  rescue ActiveRecord::ActiveRecordError, NameError, PG::Error => _e
    # Database or model not available yet (boot phase, before migrations, etc.)
    ENV.fetch(config_key, default_value)
  end

  # ENV-first resolution (the OPPOSITE precedence of .load): the ENV wins and the
  # DB is only a fallback. Use for INFRASTRUCTURE config (storage service +
  # credentials, etc.) that must be deterministic across processes and must NOT be
  # silently overridden by a DB row whose default is unset/`local` (EVO-2095).
  #
  # `env_key` lets the ENV var name differ from the DB config key (e.g. the S3
  # secret is `STORAGE_SECRET_ACCESS_KEY` in the ENV but `STORAGE_ACCESS_SECRET`
  # in the DB).
  def self.load_env_first(config_key, default_value, env_key: config_key)
    # Priority 1: environment variable wins.
    env_value = ENV.fetch(env_key, nil)
    return env_value if env_value.present?

    # Priority 2: database value as a fallback (admin-UI configured installs).
    db_value = GlobalConfig.get(config_key)[config_key]
    return db_value unless db_value.nil?

    # Priority 3: default.
    default_value
  rescue ActiveRecord::ActiveRecordError, NameError, PG::Error, Redis::BaseConnectionError => _e
    # DB/cache not available yet (boot/pre-migration, Redis down) — the ENV
    # already took precedence, so never let an infra hiccup crash the boot config.
    ENV.fetch(env_key, default_value)
  end
end
