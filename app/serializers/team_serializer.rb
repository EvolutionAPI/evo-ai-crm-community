# frozen_string_literal: true

# TeamSerializer - Optimized serialization for Team resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   TeamSerializer.serialize(@team, include_members: true)
#
module TeamSerializer
  extend self

  # Serialize single Team with optimized field selection
  #
  # @param team [Team] Team to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_members Include team members
  # @option options [Integer] :current_user_id Current user ID to check membership
  # @option options [Hash] :members_counts Precomputed { team_id => count } map
  #   to avoid an N+1 COUNT(*) when serializing a collection. Falls back to
  #   `team.team_members.count` when not provided.
  #
  # @return [Hash] Serialized team ready for Oj
  #
  def serialize(team, include_members: false, current_user_id: nil, members_counts: nil)
    members_count = members_counts ? members_counts.fetch(team.id, 0) : team.team_members.count

    result = {
      id: team.id,
      name: team.name,
      description: team.description,
      allow_auto_assign: team.allow_auto_assign,
      members_count: members_count,
      created_at: team.created_at.to_i,
      updated_at: team.updated_at.to_i
    }

    # Check if current user is member
    if current_user_id
      result['is_member'] = team.team_members.exists?(user_id: current_user_id)
    end

    # Include members
    if include_members
      result['members'] = team.members.map do |member|
        UserSerializer.serialize(member)
      end
    end

    result
  end

  # Serialize collection of Teams
  #
  # Precomputes members_count for the entire collection in one GROUP BY query
  # to keep the list endpoint at O(1) COUNT queries regardless of team count.
  #
  # @param teams [Array<Team>, ActiveRecord::Relation]
  # @param options [Hash] Same options as serialize method
  #
  # @return [Array<Hash>] Array of serialized teams
  #
  def serialize_collection(teams, **options)
    return [] unless teams

    team_ids = teams.map(&:id)
    counts = team_ids.empty? ? {} : TeamMember.where(team_id: team_ids).group(:team_id).count

    teams.map { |team| serialize(team, members_counts: counts, **options) }
  end
end
