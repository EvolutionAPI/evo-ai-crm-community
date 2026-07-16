# frozen_string_literal: true

# rake task: evo_extension_points:check_contract
#
# Guard-rail that catches breaking changes to the public extension contract
# declared in EXTENSION_POINTS.md (story 0.2) versus the live Ruby modules
# under EvoExtensionPoints (story 0.5). Wired into CI by the workflow
# .github/workflows/community-with-extension-consumer-stub.yml.
#
# The check is intentionally simple: parse the documented extension point
# names out of EXTENSION_POINTS.md and confirm a corresponding constant
# exists under EvoExtensionPoints. Renames, removals, or undocumented
# additions all fail loudly with a message that names the offending point.
# The header's advertised contract version must also match the live
# EXTENSION_POINTS_VERSION, so a documented point cannot ship under a version
# the code never bumped.

namespace :evo_extension_points do # rubocop:disable Metrics/BlockLength
  desc 'Verify EXTENSION_POINTS.md matches the live EvoExtensionPoints API'
  task check_contract: :environment do
    require 'evo_extension_points'

    md_path = Rails.root.join('EXTENSION_POINTS.md')
    abort "[evo_extension_points:check_contract] EXTENSION_POINTS.md not found at #{md_path}" unless md_path.exist?

    markdown = md_path.read
    documented = EvoExtensionPoints::ContractCheck.documented_points(markdown)
    implemented = EvoExtensionPoints::ContractCheck.implemented_points

    missing = documented - implemented
    undocumented = implemented - documented

    documented_version = EvoExtensionPoints::ContractCheck.documented_version(markdown)
    live_version = EvoExtensionPoints::EXTENSION_POINTS_VERSION

    if documented_version != live_version
      abort <<~MSG
        [evo_extension_points:check_contract] Contract version mismatch!

        EXTENSION_POINTS.md header: #{documented_version.inspect}
        EXTENSION_POINTS_VERSION:   #{live_version.inspect}

        The document header must advertise the version the code ships. Per
        ADR13 + the Compatibility Promise: a new extension point is a minor
        bump, a breaking change to an existing one is a major bump. Update
        both the header and the "Versioning history" section.
      MSG
    end

    if missing.any?
      lines = missing.map { |n| "Breaking change in extension point #{n} — needs major version bump + deprecation window" }
      abort <<~MSG
        [evo_extension_points:check_contract] Breaking change detected!

        #{lines.join("\n")}

        EXTENSION_POINTS.md declares the extension point(s) above, but no
        matching module exists under EvoExtensionPoints. This usually
        means the module was removed or renamed without updating the
        public contract — see ADR13 + the Compatibility Promise section
        of EXTENSION_POINTS.md.
      MSG
    end

    if undocumented.any?
      abort <<~MSG
        [evo_extension_points:check_contract] Undocumented extension point(s) detected!

        The following module(s) exist under EvoExtensionPoints but are
        not declared in EXTENSION_POINTS.md:

        #{undocumented.map { |n| "  - #{n}" }.join("\n")}

        Adding a new extension point requires documenting it in
        EXTENSION_POINTS.md (a minor version bump per ADR13).
      MSG
    end

    puts "[evo_extension_points:check_contract] OK — contract #{live_version}, " \
         "#{documented.size} extension point(s) documented and implemented:"
    documented.sort.each { |name| puts "  - #{name}" }
  end
end
