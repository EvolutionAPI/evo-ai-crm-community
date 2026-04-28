# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TeamSerializer do
  let(:team) { Team.create!(name: "Spec Team #{SecureRandom.hex(4)}") }

  describe '.serialize' do
    it 'reports members_count as 0 for an empty team' do
      result = described_class.serialize(team)
      expect(result[:members_count]).to eq(0)
    end

    it 'reports members_count matching the number of team_members' do
      user_a = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", name: 'Alpha')
      user_b = User.create!(email: "b-#{SecureRandom.hex(4)}@example.com", name: 'Bravo')
      team.add_members([user_a.id, user_b.id])

      result = described_class.serialize(team)

      expect(result[:members_count]).to eq(2)
    end

    it 'includes members_count in the collection serializer output' do
      user = User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", name: 'Charlie')
      team.add_members([user.id])

      result = described_class.serialize_collection([team])

      expect(result.first[:members_count]).to eq(1)
    end
  end

  describe '.serialize_collection' do
    def count_queries(label_filter: nil)
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:cached]
        next if payload[:name] == 'SCHEMA'
        next if label_filter && !payload[:sql].include?(label_filter)

        queries << payload[:sql]
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        yield
      end
      queries
    end

    it 'serializes correct counts across many teams' do
      teams = Array.new(3) { |i| Team.create!(name: "Bulk Team #{i} #{SecureRandom.hex(2)}") }
      users = Array.new(3) do |i|
        User.create!(email: "bulk-#{i}-#{SecureRandom.hex(4)}@example.com", name: "Bulk #{i}")
      end
      teams[0].add_members([users[0].id, users[1].id])
      teams[1].add_members([users[2].id])
      # teams[2] stays empty

      result = described_class.serialize_collection(teams)

      counts_by_id = result.to_h { |t| [t[:id], t[:members_count]] }
      expect(counts_by_id[teams[0].id]).to eq(2)
      expect(counts_by_id[teams[1].id]).to eq(1)
      expect(counts_by_id[teams[2].id]).to eq(0)
    end

    it 'avoids N+1: at most one COUNT query regardless of collection size' do
      teams = Array.new(5) { |i| Team.create!(name: "NPlusOne Team #{i} #{SecureRandom.hex(2)}") }
      users = Array.new(2) do |i|
        User.create!(email: "n1-#{i}-#{SecureRandom.hex(4)}@example.com", name: "N1 #{i}")
      end
      teams[0].add_members([users[0].id])
      teams[1].add_members([users[0].id, users[1].id])

      count_queries_issued = count_queries(label_filter: 'team_members') do
        described_class.serialize_collection(teams)
      end.count { |sql| sql.include?('COUNT') }

      expect(count_queries_issued).to be <= 1
    end

    it 'returns an empty array for nil input without issuing queries' do
      issued = count_queries do
        expect(described_class.serialize_collection(nil)).to eq([])
      end
      expect(issued).to be_empty
    end
  end
end
