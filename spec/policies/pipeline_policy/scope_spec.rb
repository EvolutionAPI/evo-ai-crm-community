# frozen_string_literal: true

require 'rails_helper'

# EVO-2222 (AC4): PipelinePolicy::Scope#resolve is the single place #index and the by_*
# endpoints are scoped from — public + own + default + team — with NO administrator
# bypass. Each branch is asserted on its own; comparing against Pipeline.accessible_by
# would pass even with accessible_by broken.
RSpec.describe PipelinePolicy::Scope do
  let(:owner) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:member) { User.create!(name: 'Member', email: "member-#{SecureRandom.hex(4)}@example.com") }
  let(:team) { Team.create!(name: "Team #{SecureRandom.hex(4)}") }
  let!(:team_pipeline) do
    Pipeline.create!(name: "Team #{SecureRandom.hex(4)}", pipeline_type: 'custom', visibility: :team,
                     created_by: owner, teams: [team])
  end
  let!(:private_pipeline) do
    Pipeline.create!(name: "Private #{SecureRandom.hex(4)}", pipeline_type: 'custom', visibility: :private,
                     created_by: owner)
  end
  let!(:public_pipeline) do
    Pipeline.create!(name: "Public #{SecureRandom.hex(4)}", pipeline_type: 'custom', visibility: :public,
                     created_by: owner)
  end
  let!(:own_pipeline) do
    Pipeline.create!(name: "Own #{SecureRandom.hex(4)}", pipeline_type: 'custom', visibility: :private,
                     created_by: member)
  end

  def resolve_for(user, service_authenticated: nil)
    described_class.new({ user: user, service_authenticated: service_authenticated }, Pipeline.all).resolve
  end

  context 'when the user belongs to the pipeline team' do
    before { team.team_members.create!(user: member) }

    it 'grants the team pipeline, the public one and the user own pipeline' do
      expect(resolve_for(member)).to include(team_pipeline, public_pipeline, own_pipeline)
    end

    it 'withholds another user private pipeline' do
      expect(resolve_for(member)).not_to include(private_pipeline)
    end
  end

  it 'withholds a team pipeline from someone outside its teams' do
    expect(resolve_for(member)).not_to include(team_pipeline)
  end

  it 'does not bypass for an administrator who is neither owner nor team member' do
    admin = User.create!(name: 'Admin', email: "admin-#{SecureRandom.hex(4)}@example.com")
    allow(admin).to receive(:administrator?).and_return(true) # resolve must ignore it

    expect(resolve_for(admin)).not_to include(team_pipeline, private_pipeline)
  end

  # No Current.user by design; scoping by nil would answer with public+default only.
  it 'does not scope service-to-service calls, which carry no user' do
    expect(resolve_for(nil, service_authenticated: true))
      .to include(team_pipeline, private_pipeline, public_pipeline, own_pipeline)
  end

  it 'still scopes a userless call that is not service authenticated' do
    expect(resolve_for(nil)).not_to include(team_pipeline, private_pipeline, own_pipeline)
  end
end
