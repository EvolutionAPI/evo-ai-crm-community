# frozen_string_literal: true

require 'rails_helper'

# EVO-2222 (AC4): PipelinePolicy::Scope#resolve must mirror Pipeline.accessible_by
# exactly — public + own + default + team — with NO administrator bypass. accessible_by
# has never granted admins other users' private pipelines, and the scope must not diverge.
RSpec.describe PipelinePolicy::Scope do
  let(:owner) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:member) { User.create!(name: 'Member', email: "member-#{SecureRandom.hex(4)}@example.com") }
  let(:team) { Team.create!(name: "Team #{SecureRandom.hex(4)}") }
  let!(:team_pipeline) do
    Pipeline.create!(name: 'Team', pipeline_type: 'custom', visibility: :team, created_by: owner, teams: [team])
  end
  let!(:private_pipeline) do
    Pipeline.create!(name: 'Private', pipeline_type: 'custom', visibility: :private, created_by: owner)
  end

  def resolve_for(user)
    described_class.new({ user: user }, Pipeline.all).resolve
  end

  it 'mirrors accessible_by exactly for a given user' do
    team.team_members.create!(user: member)
    expect(resolve_for(member)).to match_array(Pipeline.accessible_by(member))
  end

  it 'grants a team pipeline to a member of its team' do
    team.team_members.create!(user: member)
    expect(resolve_for(member)).to include(team_pipeline)
  end

  it 'does not bypass for an administrator who is neither owner nor team member' do
    admin = User.create!(name: 'Admin', email: "admin-#{SecureRandom.hex(4)}@example.com")
    allow(admin).to receive(:administrator?).and_return(true) # resolve must ignore it
    expect(resolve_for(admin)).not_to include(team_pipeline, private_pipeline)
  end
end
