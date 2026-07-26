# frozen_string_literal: true

# EVO-2222: Pipeline.visibility already has a `team` value and the form ships a team
# picker, but the backend had nowhere to store the chosen teams — `team_ids` were
# silently dropped on save, so a "team" pipeline behaved as private. This join table
# records which teams a team-visible pipeline is shared with; `Pipeline.accessible_by`
# reads it to grant access to those teams' members.
class CreatePipelineTeams < ActiveRecord::Migration[7.1]
  def change
    create_table :pipeline_teams, id: :uuid do |t|
      # index: false — the unique composite below already covers lookups by pipeline_id.
      t.references :pipeline, type: :uuid, null: false, foreign_key: true, index: false
      t.references :team, type: :uuid, null: false, foreign_key: true
      t.timestamps
    end
    add_index :pipeline_teams, %i[pipeline_id team_id], unique: true
  end
end
