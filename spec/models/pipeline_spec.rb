# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pipeline, type: :model do
  let(:admin_user) { User.create!(email: 'admin@example.com', name: 'Admin User') }
  let(:account_owner) { User.create!(email: 'owner@example.com', name: 'Account Owner') }

  describe 'VALID_TYPES' do
    it 'contains exactly the expected pipeline types' do
      expect(Pipeline::VALID_TYPES).to contain_exactly('sales', 'support', 'onboarding', 'custom', 'marketing')
    end

    it 'is frozen' do
      expect(Pipeline::VALID_TYPES).to be_frozen
    end

    it 'rejects pipeline_type outside VALID_TYPES' do
      pipeline = Pipeline.new(name: 'Bad', pipeline_type: 'lead', created_by: admin_user)
      expect(pipeline).not_to be_valid
      expect(pipeline.errors[:pipeline_type]).to be_present
    end
  end

  describe '.accessible_by' do
    let!(:default_private_pipeline) do
      described_class.create!(
        name: 'Default Pipeline',
        pipeline_type: 'sales',
        visibility: :private,
        is_default: true,
        created_by: admin_user
      )
    end

    let!(:private_pipeline) do
      described_class.create!(
        name: 'Admin Private Pipeline',
        pipeline_type: 'custom',
        visibility: :private,
        is_default: false,
        created_by: admin_user
      )
    end

    let!(:public_pipeline) do
      described_class.create!(
        name: 'Public Pipeline',
        pipeline_type: 'support',
        visibility: :public,
        is_default: false,
        created_by: admin_user
      )
    end

    let!(:owner_pipeline) do
      described_class.create!(
        name: 'Owner Pipeline',
        pipeline_type: 'custom',
        visibility: :private,
        is_default: false,
        created_by: account_owner
      )
    end

    context 'when queried by account owner (non-creator of default pipeline)' do
      subject(:accessible) { Pipeline.accessible_by(account_owner) }

      it 'includes default pipelines created by another user (AC1)' do
        expect(accessible).to include(default_private_pipeline)
      end

      it 'excludes private non-default pipelines from another user (AC2)' do
        expect(accessible).not_to include(private_pipeline)
      end

      it 'includes public pipelines (AC3)' do
        expect(accessible).to include(public_pipeline)
      end

      it 'includes own pipelines (AC4)' do
        expect(accessible).to include(owner_pipeline)
      end
    end

    context 'when queried by the creator (admin user)' do
      subject(:accessible) { Pipeline.accessible_by(admin_user) }

      it 'includes all own pipelines' do
        expect(accessible).to include(default_private_pipeline, private_pipeline, public_pipeline)
      end

      it 'excludes private pipelines from other users' do
        expect(accessible).not_to include(owner_pipeline)
      end
    end

    # EVO-2222: `team` visibility grants access to the members of the pipeline's teams.
    # Before this, `team` matched no branch and behaved as private.
    context 'with team visibility' do
      let(:team) { Team.create!(name: "Team #{SecureRandom.hex(4)}") }
      let(:member) { User.create!(email: "member-#{SecureRandom.hex(4)}@example.com", name: 'Member') }
      let(:non_member) { User.create!(email: "outsider-#{SecureRandom.hex(4)}@example.com", name: 'Outsider') }
      let!(:team_pipeline) do
        described_class.create!(
          name: 'Team Pipeline', pipeline_type: 'custom', visibility: :team,
          is_default: false, created_by: admin_user, teams: [team]
        )
      end

      before { team.team_members.create!(user: member) }

      it 'persists the picker selection via team_ids= — no longer discarded (AC1)' do
        expect(team_pipeline.reload.team_ids).to contain_exactly(team.id)
      end

      it 'includes a team pipeline for a member of one of its teams (AC2)' do
        expect(described_class.accessible_by(member)).to include(team_pipeline)
      end

      it 'excludes a team pipeline from a non-member (AC2)' do
        expect(described_class.accessible_by(non_member)).not_to include(team_pipeline)
      end

      it 'does not reach a member of a DIFFERENT team' do
        other = Team.create!(name: "Other #{SecureRandom.hex(4)}")
        other.team_members.create!(user: non_member)
        expect(described_class.accessible_by(non_member)).not_to include(team_pipeline)
      end

      it 'drops the join when a shared team is deleted, leaving the pipeline' do
        extra = Team.create!(name: "Extra #{SecureRandom.hex(4)}")
        team_pipeline.teams << extra

        expect { extra.destroy! }.to change(PipelineTeam, :count).by(-1)
        expect(described_class.exists?(team_pipeline.id)).to be(true)
      end
    end
  end
end
