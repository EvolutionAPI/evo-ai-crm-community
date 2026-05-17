# frozen_string_literal: true

module EvoExtensionPoints
  # Compares the public extension point contract declared in
  # EXTENSION_POINTS.md against the modules actually exposed under
  # EvoExtensionPoints. Used by the rake task
  # evo_extension_points:check_contract (lib/tasks/evo_extension_points.rake)
  # which the community-with-enterprise-stub CI workflow runs on every PR.
  #
  # Extension point names are normalized to lowercase snake_case strings on
  # both sides:
  #   - From EXTENSION_POINTS.md: parsed out of `### N. \`feature_gate\``
  #     headings and from the "## Extension points" overview table.
  #   - From the live API: each constant directly defined under
  #     EvoExtensionPoints that is itself a Module (i.e. an extension
  #     point), with its name underscored. Internal infrastructure
  #     (KNOWN_KEYS, UnknownExtensionPoint, ContractCheck) is excluded.
  module ContractCheck
    INFRASTRUCTURE = %w[
      KNOWN_KEYS
      UnknownExtensionPoint
      ContractCheck
    ].freeze

    HEADING_PATTERN = /^###\s+\d+\.\s+`([a-z][a-z0-9_]*)`/m

    class << self
      def documented_points(markdown)
        markdown.scan(HEADING_PATTERN).flatten.map(&:downcase).uniq
      end

      def implemented_points
        EvoExtensionPoints.constants(false).filter_map do |const_name|
          next if INFRASTRUCTURE.include?(const_name.to_s)

          value = EvoExtensionPoints.const_get(const_name)
          next unless value.is_a?(Module)

          underscore(const_name.to_s)
        end
      end

      private

      def underscore(camel)
        camel
          .gsub('::', '/')
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .downcase
      end
    end
  end
end
