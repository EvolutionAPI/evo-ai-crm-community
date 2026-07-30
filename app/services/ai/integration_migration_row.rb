# frozen_string_literal: true

# One line of the integration credential migration report: what secret a
# consumer uses today and what it would use after the import.
#
# The comparison is by VALUE, not by row id: the point is proving that what goes
# out on the wire does not change.
class Ai::IntegrationMigrationRow
  VERDICT_SKIPPED = 'PULADO'

  attr_reader :subject, :before_value, :after_value, :origin, :skipped

  def initialize(subject:, origin:, before_value: nil, after_value: nil, skipped: false)
    @subject = subject
    @before_value = before_value
    @after_value = after_value
    @origin = origin
    @skipped = skipped
  end

  def skipped?
    @skipped
  end

  # A skipped consumer is not a failure: it simply has nothing to migrate, and
  # saying so keeps it from reading as a pending item nobody addressed.
  def ok?
    skipped? || before_value == after_value
  end

  def verdict
    return VERDICT_SKIPPED if skipped?

    ok? ? 'OK' : 'DIVERGE'
  end

  def to_line
    format(
      '%<subject>-34s ANTES=%<before>-12s DEPOIS=%<after>-12s %<verdict>-8s %<origin>s',
      subject: subject, before: mask(before_value), after: mask(after_value),
      verdict: verdict, origin: origin
    )
  end

  # The report goes to the logs, so it carries the mask, never the secret.
  def mask(value)
    return '(nenhum)' if value.blank?

    "••••#{value.chars.last(4).join}"
  end
end
