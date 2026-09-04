# frozen_string_literal: true

require 'rails_helper'

# Every CONCURRENTLY index build in db/migrate goes through
# ConcurrentIndexMigration (see lib/): a bare add_index or raw SQL would skip the
# INVALID leftover of a failed build. Awk twin: .github/workflows/concurrent-index-guard.yml.
RSpec.describe 'CONCURRENTLY index builds use ConcurrentIndexMigration (CRM-402)' do # rubocop:disable RSpec/DescribeClass
  def migrations_using_concurrently
    Dir[Rails.root.join('db/migrate/*.rb')].select { |path| File.read(path).match?(/:concurrently|index\s+concurrently/i) }
  end

  def without_comment_lines(source)
    source.gsub(/^[ \t]*#.*\n?/, '')
  end

  # A bare add_index anywhere on a line (so `dir.up { add_index` counts), up to a
  # blank line or the next statement, so a following remove_index is not pinned on it.
  def bare_concurrent_add_index_calls(source)
    without_comment_lines(source)
      .scan(/(?<!\w)add_index\b.*?(?=\n\s*\n|\n\s*(?:add_|remove_|create_|change_|execute\b|end\b)|\z)/m)
      .select { |call| call.include?(':concurrently') }
  end

  def raw_concurrent_creates(source)
    without_comment_lines(source).scan(/create\s+(?:unique\s+)?index\s+concurrently/i)
  end

  it 'finds the known CONCURRENTLY migrations (guards against a broken glob)' do
    expect(migrations_using_concurrently.map { |p| File.basename(p) })
      .to include('20260513120001_add_index_to_contacts_type.rb',
                  '20260727120000_add_capture_form_lead_indexes.rb',
                  '20260826120000_add_purchase_identity_index_to_pipeline_items.rb')
  end

  it 'never builds a CONCURRENTLY index outside the helper' do
    offenders = migrations_using_concurrently.filter_map do |path|
      source = File.read(path)
      calls = bare_concurrent_add_index_calls(source) + raw_concurrent_creates(source)
      "#{File.basename(path)}:\n#{calls.join("\n")}" if calls.any?
    end

    expect(offenders).to be_empty, <<~MSG
      Use `include ConcurrentIndexMigration` + `add_index_concurrently(table, cols, name: ...)`
      instead of `add_index ... algorithm: :concurrently` or raw CREATE INDEX CONCURRENTLY
      (see lib/concurrent_index_migration.rb):

      #{offenders.join("\n\n")}
    MSG
  end

  describe 'the heuristic itself' do
    it 'flags a bare add_index whose options span lines' do
      source = "  def change\n    add_index :contacts, :type,\n              algorithm: :concurrently, if_not_exists: true\n  end\n"
      expect(bare_concurrent_add_index_calls(source).size).to eq(1)
    end

    it 'flags a bare add_index inside a reversible block' do
      source = "    reversible do |dir|\n      dir.up { add_index :t, :c, name: 'x', algorithm: :concurrently }\n    end\n"
      expect(bare_concurrent_add_index_calls(source).size).to eq(1)
    end

    it 'flags raw SQL CREATE INDEX CONCURRENTLY' do
      source = "    execute \"CREATE UNIQUE INDEX CONCURRENTLY idx ON t (c)\"\n"
      expect(raw_concurrent_creates(source).size).to eq(1)
    end

    it 'does not pin a following remove_index ... :concurrently on a plain add_index' do
      source = "  def up\n    add_index :contacts, :type, name: 'x'\n    " \
               "remove_index :contacts, name: 'y', algorithm: :concurrently, if_exists: true\n  end\n"
      expect(bare_concurrent_add_index_calls(source)).to be_empty
    end

    it 'ignores a comment line inside the call' do
      source = "    add_index :contacts, :type,\n              # was algorithm: :concurrently once\n              name: 'x'\n"
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
