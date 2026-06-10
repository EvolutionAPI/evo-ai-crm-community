# Server-side companion to the frontend `useContactPiiMasking` hook (EVO-1551).
#
# Masks phone, email and WhatsApp identifier in API responses when the account
# flag `settings.mask_contact_pii` is on AND the current user is not an admin.
#
# Goal: stop the Network-tab leak where the masked UI hides the data but the
# JSON payload still exposes it. This is a defence-in-depth layer; the frontend
# hook continues to mask too.
#
# Rules mirror the TS helpers in `evo-ai-frontend-community/src/utils/contact/maskContactPii.ts`.
module ContactPiiMasker
  module_function

  def should_mask?
    flag_enabled = Current.account.is_a?(Hash) &&
                   Current.account.dig('settings', 'mask_contact_pii') == true
    return false unless flag_enabled

    # When no user is bound — ActionCable listeners reacting to inbound
    # messages run in a background context where `Current.user` is nil but the
    # payload is about to be broadcast to agent sockets. Default to MASKING
    # there: leaking raw PII over the websocket is exactly what EVO-1551 is
    # supposed to fix. Admins requesting the same record via HTTP carry
    # `Current.user` and still receive the raw value below.
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
  # (e.g. "553140204020"). When that happens the name itself is PII. Only mask
  # when the name looks predominantly numeric — never touch alphabetic names.
  def mask_phone_like_name(raw)
    return raw if raw.blank?

    digits = raw.to_s.gsub(/\D/, '')
    return raw if digits.length < 8
    return raw if raw.to_s.match?(/[a-zA-Z]/)

    mask_phone(raw)
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
end
