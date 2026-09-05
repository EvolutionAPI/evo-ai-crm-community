module UserAttributeHelpers
  extend ActiveSupport::Concern

  def available_name
    self[:display_name].presence || name
  end

  def availability_status
    availability.presence || 'offline'
  end

  def auto_offline
    false
  end

  def inviter
    nil
  end

  def administrator?
    # `super_admin` is the installation-owner role introduced alongside the
    # auth-service split (see EvoAuth migration PromoteFirstUserToSuperAdmin).
    # It must be treated as an admin in the CRM context too — otherwise the
    # bootstrap user loses the admin bypass on inbox / conversation visibility
    # and the conversations list goes empty until they're explicitly added as
    # an inbox member.
    Current.evo_role_key.in?(%w[super_admin account_owner administrator admin])
  end

  def agent?
    !administrator?
  end

  def role
    administrator? ? 'administrator' : 'agent'
  end

  # Real permission check via the PermissionResolver seam (community default:
  # auth-service; a consumer may resolve per scope). Shares the per-request
  # cache namespace with EvoPermissionConcern so a verdict is fetched once per
  # (user, scope, permission). Fail-closed on errors.
  def has_permission?(permission)
    scope_id = EvoExtensionPoints::RuntimeContext.current_scope_id
    cache = (Current.evo_permission_cache ||= {})
    cache_key = "user:#{id}:#{scope_id}:#{permission}"
    return cache[cache_key] if cache.key?(cache_key)

    cache[cache_key] = EvoExtensionPoints::PermissionResolver.allowed?(
      user_id: id, permission_key: permission.to_s, scope_id: scope_id
    )
  rescue StandardError => e
    Rails.logger.error "Error checking permission #{permission} for user #{id}: #{e.message}"
    false
  end

  # Used internally for Evolution in Evolution
  def hmac_identifier
    hmac_key = GlobalConfig.get('EVOLUTION_INBOX_HMAC_KEY')['EVOLUTION_INBOX_HMAC_KEY']
    return OpenSSL::HMAC.hexdigest('sha256', hmac_key, email) if hmac_key.present?

    ''
  end
end
