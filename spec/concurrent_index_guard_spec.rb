# frozen_string_literal: true

require 'rails_helper'

# CRM-402 — every CONCURRENTLY index build goes through ConcurrentIndexMigration.
#
# A bare `add_index ... algorithm: :concurrently, if_not_exists: true` skips the
# INVALID leftover of a failed build and lets the migration be recorded as
# applied with a dead index (index_pipeline_items_on_purchase_identity,
# 2026-08-29). The helper drops that leftover first; this spec keeps the next
# migration from repeating the bare form. Scans db/migrate only — the helper
# itself is the one place allowed to call add_index with :concurrently.
RSpec.describe 'CONCURRENTLY index builds use ConcurrentIndexMigration (CRM-402)' do # rubocop:disable RSpec/DescribeClass
  def migrations_using_concurrently
    Dir[Rails.root.join('db/migrate/*.rb')].select { |path| File.read(path).include?(':concurrently') }
  end

  # Each bare add_index call up to a blank line or the next statement (another
  # call, `end`) — so a remove_index ... :concurrently right after it is not
  # pinned on it. A call carrying `algorithm: :concurrently` is the pattern under ban.
  def bare_concurrent_add_index_calls(source)
    source.scan(/^\s*add_index\b(?!_concurrently).*?(?=\n\s*\n|\n\s*(?:add_|remove_|create_|change_|execute\b|end\b)|\z)/m)
          .select { |call| call.include?(':concurrently') }
  end

  it 'finds the known CONCURRENTLY migrations (guards against a broken glob)' do
    expect(migrations_using_concurrently.map { |p| File.basename(p) })
      .to include('20260513120001_add_index_to_contacts_type.rb',
                  '20260727120000_add_capture_form_lead_indexes.rb',
                  '20260826120000_add_purchase_identity_index_to_pipeline_items.rb')
  end

  it 'never builds a CONCURRENTLY index with a bare add_index' do
    offenders = migrations_using_concurrently.filter_map do |path|
      calls = bare_concurrent_add_index_calls(File.read(path))
      "#{File.basename(path)}:\n#{calls.join("\n")}" if calls.any?
    end

    expect(offenders).to be_empty, <<~MSG
      Use `include ConcurrentIndexMigration` + `add_index_concurrently(table, cols, name: ...)`
      instead of `add_index ... algorithm: :concurrently` (see lib/concurrent_index_migration.rb):

      #{offenders.join("\n\n")}
    MSG
  end

  describe 'the heuristic itself' do
    it 'flags a bare add_index whose options span lines' do
      source = "  def change\n    add_index :contacts, :type,\n              algorithm: :concurrently, if_not_exists: true\n  end\n"
      expect(bare_concurrent_add_index_calls(source).size).to eq(1)
    end

    it 'does not pin a following remove_index ... :concurrently on a plain add_index' do
      source = "  def up\n    add_index :contacts, :type, name: 'x'\n    " \
               "remove_index :contacts, name: 'y', algorithm: :concurrently, if_exists: true\n  end\n"
      expect(bare_concurrent_add_index_calls(source)).to be_empty
    end

    it 'ignores add_index_concurrently' do
      source = "    add_index_concurrently :contacts, :type, name: 'x'\n"
      expect(bare_concurrent_add_index_calls(source)).to be_empty
    end
  end

  it 'includes the helper in every migration that builds a CONCURRENTLY index' do
    missing = migrations_using_concurrently.select do |path|
      source = File.read(path)
      source.include?('add_index_concurrently') && source.exclude?('include ConcurrentIndexMigration')
    end

    expect(missing.map { |p| File.basename(p) }).to be_empty
  end
end
