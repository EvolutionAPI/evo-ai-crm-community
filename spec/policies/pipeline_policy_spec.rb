# frozen_string_literal: true

require 'rails_helper'

# EVO-2204: the record-level rules AND the permission with the visibility model. The
# request specs cover the pipelines controller; these pin the rules themselves, which is
# what every other consumer asks — including oauth/pipeline_items_controller, whose
# identity is the token's resource owner and which has no service-token bypass. That
# path is a deliberate behaviour change (an OAuth app can no longer read a pipeline its
# resource owner did not create) and is asserted here rather than left to review.
RSpec.describe PipelinePolicy do
  let(:owner) { User.create!(name: 'Owner', email: "owner-#{SecureRandom.hex(4)}@example.com") }
  let(:other) { User.create!(name: 'Other', email: "other-#{SecureRandom.hex(4)}@example.com") }
  let(:private_pipeline) do
    Pipeline.create!(name: "Private #{SecureRandom.hex(4)}", pipeline_type: 'custom', created_by: owner)
  end

  # Permissions granted throughout: visibility is the only variable under test.
  before do
    [owner, other].each { |u| allow(u).to receive(:has_permission?).and_return(true) }
  end

  def policy_for(user, pipeline, service_authenticated: nil)
    described_class.new(
      { user: user, account: nil, service_authenticated: service_authenticated }, pipeline
    )
  end

  def record_rules
    %i[show? view? update? destroy? archive? set_as_default? stats? dependents?]
  end

  it 'grants the creator every record-level rule' do
    policy = policy_for(owner, private_pipeline)

    record_rules.each { |rule| expect(policy.public_send(rule)).to be(true), "#{rule} denied the creator" }
  end

  it 'denies a non-creator every record-level rule on a private pipeline' do
    policy = policy_for(other, private_pipeline)

    record_rules.each { |rule| expect(policy.public_send(rule)).to be(false), "#{rule} leaked to a non-creator" }
  end

  it 'denies a non-creator holding no permission, so both halves are required' do
    allow(other).to receive(:has_permission?).and_return(false)

    expect(policy_for(other, private_pipeline).show?).to be(false)
  end

  it 'grants a permitted user on a public pipeline' do
    public_pipeline = Pipeline.create!(name: "Public #{SecureRandom.hex(4)}", pipeline_type: 'custom',
                                       created_by: owner, visibility: :public)

    expect(policy_for(other, public_pipeline).show?).to be(true)
  end

  it 'grants a permitted user on the account default' do
    default_pipeline = Pipeline.create!(name: "Default #{SecureRandom.hex(4)}", pipeline_type: 'custom',
                                        created_by: owner, is_default: true)

    expect(policy_for(other, default_pipeline).show?).to be(true)
  end

  context 'with a team-visible pipeline' do
    let(:team) { Team.create!(name: "Team #{SecureRandom.hex(4)}") }
    let(:team_pipeline) do
      Pipeline.create!(name: "Team #{SecureRandom.hex(4)}", pipeline_type: 'custom',
                       created_by: owner, visibility: :team, teams: [team])
    end

    it 'grants a member of a shared team' do
      team.team_members.create!(user: other)

      expect(policy_for(other, team_pipeline).show?).to be(true)
    end

    it 'denies a user outside the shared teams' do
      expect(policy_for(other, team_pipeline).show?).to be(false)
    end
  end

  # Mirrors accessible_by, which never granted admins other users' private pipelines.
  it 'does not bypass for an administrator who is not the creator' do
    allow(other).to receive(:administrator?).and_return(true)

    expect(policy_for(other, private_pipeline).show?).to be(false)
  end

  # index? stays permission-only: the list is narrowed by Scope#resolve, not by the rule.
  it 'keeps index? permission-only' do
    expect(policy_for(other, private_pipeline).index?).to be(true)
  end
end
