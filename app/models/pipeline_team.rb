# frozen_string_literal: true

# EVO-2222: join between a `team`-visible pipeline and the teams it is shared with.
# The pipeline's members-with-access are the members of these teams.
class PipelineTeam < ApplicationRecord
  belongs_to :pipeline
  belongs_to :team

  # Mirrors the unique index so a repeated team in the picker's payload surfaces as a
  # validation error instead of a RecordNotUnique from the database (same guard
  # TeamMember carries for its own pair).
  validates :team_id, uniqueness: { scope: :pipeline_id }
end
