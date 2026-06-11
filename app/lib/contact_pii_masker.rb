# Server-side companion to the frontend `useContactPiiMasking` hook (EVO-1551).
#
# Masks phone, email and WhatsApp identifier in API responses / websocket
# frames when the account flag `settings.mask_contact_pii` is on.
#
# Two predicates because there are two audience shapes on the server:
#
#   - `should_mask?` — used by per-request serializers (HTTP responses,
#     point-to-point WS frames). Honours `Current.user`: admin tiers see the
#     raw value; agents (and unbound contexts such as listeners reacting to
#     inbound messages — see EVO-1551 round 2 / CB-2) see the masked value.
#
#   - `account_flag_enabled?` — used by broadcasts whose audience is the
#     whole account (e.g. `contact.updated`, `conversation.created`) and
#     therefore includes agents regardless of who triggered the event. The
#     caller's `Current.user` is irrelevant: if any agent in the account is
#     subscribed, masking must apply. Admins still get the raw payload via the
#     subsequent HTTP refresh, which carries their `Current.user`. This is
#     the fix for EVO-1551 round 3 / CB-3 + CB-4.
#
# Goal: stop the Network-tab leak where the masked UI hides the data but the
# JSON payload still exposes it. Defence-in-depth alongside the frontend hook.
#
# Rules mirror the TS helpers in `evo-ai-frontend-community/src/utils/contact/maskContactPii.ts`.
module ContactPiiMasker
  module_function

  def account_flag_enabled?
    account = resolved_account
    account.is_a?(Hash) &&
      account.dig('settings', 'mask_contact_pii') == true
  end

  # Returns the account hash used for masking decisions.
  #
  # `Current.account` is populated by `EvoAuthConcern` (HTTP pipeline only).
  # Sidekiq workers, ActionCable listeners and any job-triggered broadcast
  # run on threads where `Current.account` is nil, which made the predicate
  # silently fail-open and ship raw PII on the wire — EVO-1551 rounds
  # 2/3/3.1/4 were all this same bug in a new egress path.
  #
  # Falling back to `RuntimeConfig.account` (the persisted source the HTTP
  # concern itself reads from at evo_auth_concern.rb:62) closes the whole
  # class of "no one set Current.account on this thread" leaks at the
  # predicate level instead of patching each new caller.
  def resolved_account
    return Current.account if Current.account.is_a?(Hash)

    RuntimeConfig.account
  end

  def should_mask?
    return false unless account_flag_enabled?

    user = Current.user
    return true if user.nil?
    return false if user.respond_to?(:administrator?) && user.administrator?

    true
  end

  def mask_phone(raw)
    return nil if raw.blank?

    digits_only = raw.to_s.gsub(/\D/, '')
    return nil if digits_only.empty?
    return raw.to_s.gsub(/\d/, '*') if digits_only.length < 4

    last_dash = raw.to_s.rindex('-')
    if last_dash && last_dash.positive?
      before = raw.to_s[0...last_dash]
      after = raw.to_s[last_dash..]
      return "#{before.sub(/\d+(?=\D*\z)/, '****')}#{after}" if before.match?(/\d/) && after.match?(/\d/)
    end

    total = digits_only.length
    seen = 0
    raw.to_s.each_char.map do |ch|
      if ch.match?(/\d/)
        seen += 1
        seen > total - 4 ? ch : '*'
      else
        ch
      end
    end.join
  end

  def mask_email(raw)
    return nil if raw.blank?

    at_idx = raw.to_s.index('@')
    return '***' if at_idx.nil?

    local = raw.to_s[0...at_idx]
    domain = raw.to_s[at_idx..]

    return "***#{domain}" if local.empty?
    return "*#{domain}" if local.length == 1

    "#{local[0]}***#{domain}"
  end

  # Many WhatsApp contacts arrive with the raw phone number as their `name`
  # (e.g. "553140204020"). When that happens the name itself is PII.
  #
  # EVO-1551 round 5 nit: a previous version short-circuited on any letter,
  # which left "Cliente 11999998888" untouched (phone fully exposed inside
  # a mixed string). Fix: when the string contains an 8+ digit run, mask
  # that run in place; otherwise (no embedded number) return unchanged.
  PHONE_RUN_REGEX = /\d[\d\s().-]{6,}\d/.freeze

  def mask_phone_like_name(raw)
    return raw if raw.blank?

    str = raw.to_s

    return mask_phone(str) unless str.match?(/[a-zA-Z]/)

    str.gsub(PHONE_RUN_REGEX) do |run|
      run.gsub(/\D/, '').length >= 8 ? mask_phone(run) : run
    end
  end

  def mask_identifier(raw)
    return nil if raw.blank?

    at_idx = raw.to_s.index('@')
    if at_idx.nil?
      masked = mask_phone(raw)
      return masked.presence || '***'
    end

    prefix = raw.to_s[0...at_idx]
    suffix = raw.to_s[at_idx..]
    masked_prefix = mask_phone(prefix)
    return "***#{suffix}" if masked_prefix.blank?

    "#{masked_prefix}#{suffix}"
  end

  # EVO-1551 round 4 — H2 fix.
  # `Message#content_attributes` is a Rails `store` hash where the WebWidget
  # pre-chat form persists captured PII: `submitted_email` (form's email
  # field) and `submitted_values` (every form field, including phone). Both
  # leak through serializers that include `content_attributes` verbatim
  # (MessageSerializer:25, ConversationSerializer:205). Strip those keys
  # when masking is on; the rest of the hash (csat_survey_response,
  # in_reply_to, items, deleted, etc.) is non-PII and must be preserved
  # so the UI keeps rendering CSAT replies, reply context and so on.
  PII_BEARING_CONTENT_ATTRIBUTE_KEYS = %w[submitted_email submitted_values email].freeze

  def scrub_pii_content_attributes(attrs)
    return attrs if attrs.blank?
    return attrs unless attrs.is_a?(Hash)

    scrubbed = attrs.dup
    PII_BEARING_CONTENT_ATTRIBUTE_KEYS.each do |key|
      scrubbed.delete(key)
      scrubbed.delete(key.to_sym)
    end
    scrubbed
  end
end
