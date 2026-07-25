# frozen_string_literal: true

# EVO-2222: join between a `team`-visible pipeline and the teams it is shared with.
# The pipeline's members-with-access are the members of these teams.
class PipelineTeam < ApplicationRecord
  belongs_to :pipeline
  belongs_to :team
end
