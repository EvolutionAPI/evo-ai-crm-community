# frozen_string_literal: true

# One line of the migration report: which credential is in effect for a subject
# before the import and which would be after it.
#
# The comparison is by KEY VALUE, not row id — the point is proving the key in
# use did not change (NFR1).
class Ai::CredentialMigrationRow
  attr_reader :subject, :before_key, :after_key, :origin

  def initialize(subject:, before_key:, after_key:, origin:)
    @subject = subject
    @before_key = before_key
    @after_key = after_key
    @origin = origin
  end

  def ok?
    before_key == after_key
  end

  def verdict
    ok? ? 'OK' : 'DIVERGE'
  end

  def to_line
    format(
      '%<subject>-28s ANTES=%<before>-12s DEPOIS=%<after>-12s %<verdict>-10s %<origin>s',
      subject: subject, before: mask(before_key), after: mask(after_key),
      verdict: verdict, origin: origin
    )
  end

  # The report goes to the logs, so it carries the mask, never the key.
  def mask(value)
    return '(nenhuma)' if value.blank?

    "••••#{value.chars.last(4).join}"
  end
end
