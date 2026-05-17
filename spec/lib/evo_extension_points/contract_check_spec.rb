# frozen_string_literal: true

require 'rails_helper'
require 'evo_extension_points'

RSpec.describe EvoExtensionPoints::ContractCheck do
  describe '.documented_points' do
    it 'parses extension point names from `### N. `name`` headings' do
      markdown = <<~MD
        # Extension Points

        ## Extension points

        ### 1. `feature_gate`

        Some prose.

        ### 2. `tenant_context`

        ### 3. `plugin_loader`

        ### 4. `theme_tokens`

        ### 5. `data_export`
      MD

      expect(described_class.documented_points(markdown))
        .to match_array(%w[feature_gate tenant_context plugin_loader theme_tokens data_export])
    end

    it 'is case-insensitive and deduplicated' do
      markdown = <<~MD
        ### 1. `feature_gate`
        ### 2. `feature_gate`
      MD

      expect(described_class.documented_points(markdown)).to eq(%w[feature_gate])
    end

    it 'ignores headings that are not extension point declarations' do
      markdown = <<~MD
        ### 1. Some Section
        ### 2. Another Section
      MD

      expect(described_class.documented_points(markdown)).to eq([])
    end
  end

  describe '.implemented_points' do
    it 'lists every Module constant directly defined under EvoExtensionPoints' do
      points = described_class.implemented_points
      expect(points).to include('feature_gate', 'tenant_context', 'plugin_loader', 'theme_tokens', 'data_export')
    end

    it 'excludes internal infrastructure (KNOWN_KEYS, UnknownExtensionPoint, ContractCheck)' do
      points = described_class.implemented_points
      expect(points).not_to include('known_keys', 'unknown_extension_point', 'contract_check')
    end
  end

  describe 'integration with the real EXTENSION_POINTS.md' do
    let(:markdown) { Rails.root.join('EXTENSION_POINTS.md').read }

    it 'has the documented points and the implemented points fully matching' do
      documented = described_class.documented_points(markdown).sort
      implemented = described_class.implemented_points.sort

      expect(documented).to eq(implemented),
                            "Drift between EXTENSION_POINTS.md and EvoExtensionPoints API.\n" \
                            "Documented only: #{(documented - implemented).inspect}\n" \
                            "Implemented only: #{(implemented - documented).inspect}"
    end
  end

  describe 'breaking change detection (simulated)' do
    it 'flags an extension point that was renamed in the markdown but kept in the API' do
      tampered = <<~MD
        ### 1. `feature_gate`
        ### 2. `renamed_tenant_context`
        ### 3. `plugin_loader`
        ### 4. `theme_tokens`
        ### 5. `data_export`
      MD

      documented = described_class.documented_points(tampered)
      implemented = described_class.implemented_points

      missing = documented - implemented
      undocumented = implemented - documented

      expect(missing).to include('renamed_tenant_context')
      expect(undocumented).to include('tenant_context')
    end

    it 'flags an extension point that was removed from the markdown but kept in the API' do
      tampered = <<~MD
        ### 1. `feature_gate`
        ### 2. `plugin_loader`
        ### 3. `theme_tokens`
        ### 4. `data_export`
      MD

      documented = described_class.documented_points(tampered)
      implemented = described_class.implemented_points

      undocumented = implemented - documented
      expect(undocumented).to include('tenant_context')
    end
  end
end
