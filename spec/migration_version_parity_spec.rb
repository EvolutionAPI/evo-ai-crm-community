# frozen_string_literal: true

require 'rails_helper'

# EVO-2090 — collision-free migration versions.
#
# evo-ai-crm-community and evo-auth-service-community run as SEPARATE apps but
# point at the SAME database, sharing ONE `schema_migrations` table. If both ever
# create a migration with the same version (14-digit timestamp), Rails records it
# once and SKIPS the second app's migration forever -> missing DDL -> boot crash
# (this is what broke `messages.source`, EVO-1911).
#
# To make a collision IMPOSSIBLE BY CONSTRUCTION -- no shared-table split, no
# separate database, no cross-repo CI -- each app owns a DISJOINT slice of the
# version space by PARITY:
#
#   * CRM (this repo) -> EVEN versions  (...0, ...2, ...4, ...6, ...8)
#   * auth            -> ODD  versions  (...1, ...3, ...5, ...7, ...9)
#
# even and odd are disjoint, so the two apps can never pick the same version.
# Each repo enforces its OWN parity locally (this spec), catching a bad migration
# in the PR that introduces it -- no access to the other repo required.
#
# Migrations created before this convention are grandfathered via CUTOFF.
RSpec.describe 'Migration version parity (EVO-2090)' do
  # The convention takes effect from this timestamp. A migration whose version is
  # >= CUTOFF must be EVEN; anything older predates the rule and is exempt.
  let(:cutoff) { 20_260_713_000_000 }

  def migration_versions
    Dir[Rails.root.join('db/migrate/*.rb')]
      .map { |path| File.basename(path)[/\A\d{14}/]&.to_i }
      .compact
  end

  it 'finds migrations (guards against a broken glob / wrong path)' do
    expect(migration_versions).not_to be_empty
  end

  # CRM owns EVEN versions; auth owns ODD. Any ODD version at/after the cutoff can
  # collide with an auth migration in the shared schema_migrations table.
  it 'every migration created under the convention (version >= CUTOFF) uses an EVEN version' do
    offenders = migration_versions.select { |version| version >= cutoff && version.odd? }

    expect(offenders).to be_empty, <<~MSG
      Migration version collision guard (EVO-2090): this repo (CRM) owns EVEN
      migration versions; auth owns ODD. The versions below are ODD and >= the
      convention cutoff (#{cutoff}), so they can collide with an auth migration in
      the shared `schema_migrations` table:

        #{offenders.sort.join("\n        ")}

      Fix: bump the migration timestamp by 1 second so its version becomes even.
    MSG
  end

  it 'the rule is active — an odd version at/after the cutoff would be flagged' do
    # Sanity: proves the predicate actually rejects odd versions in-range, so a
    # green suite means the real check above is meaningful (not vacuously true).
    odd_in_range = [cutoff + 1, cutoff + 3]
    expect(odd_in_range.select { |version| version >= cutoff && version.odd? }).to eq(odd_in_range)
    expect(cutoff).to be_even
  end
end
