# frozen_string_literal: true

require 'rails_helper'
require 'evo_extension_points'

RSpec.describe EvoExtensionPoints::ContractCheck do
  describe '.documented_points' do
    it 'parses extension point names from `### N. `name`` headings' do
      markdown = <<~MD
        # Extension Points

        ## Extension points

        ### 1. `capability_gate`

        Some prose.

        ### 2. `runtime_context`

        ### 3. `plugin_loader`

        ### 4. `theme_tokens`

        ### 5. `data_export`
      MD

      expect(described_class.documented_points(markdown))
        .to match_array(%w[capability_gate runtime_context plugin_loader theme_tokens data_export])
    end

    it 'is case-insensitive and deduplicated' do
      markdown = <<~MD
        ### 1. `capability_gate`
        ### 2. `capability_gate`
      MD

      expect(described_class.documented_points(markdown)).to eq(%w[capability_gate])
    end

    it 'ignores headings that are not extension point declarations' do
      markdown = <<~MD
        ### 1. Some Section
        ### 2. Another Section
      MD

      expect(described_class.documented_points(markdown)).to eq([])
    end
  end

  describe '.documented_version' do
    it 'parses the contract version out of the document header' do
      expect(described_class.documented_version("# Extension Points\n\n**Contract version:** `2.1.0` (SemVer)\n"))
        .to eq('2.1.0')
    end

    it 'returns nil when the header is missing or malformed' do
      expect(described_class.documented_version("# Extension Points\n\nContract version: 2.1.0\n")).to be_nil
    end
  end

  describe '.implemented_points' do
    it 'lists every Module constant directly defined under EvoExtensionPoints' do
      points = described_class.implemented_points
      expect(points).to include('capability_gate', 'runtime_context', 'plugin_loader', 'theme_tokens', 'data_export')
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

    it 'advertises the contract version the code actually ships' do
      expect(described_class.documented_version(markdown))
        .to eq(EvoExtensionPoints::EXTENSION_POINTS_VERSION),
            'EXTENSION_POINTS.md header and EXTENSION_POINTS_VERSION disagree — bump both together.'
    end
  end

  describe 'breaking change detection (simulated)' do
    it 'flags an extension point that was renamed in the markdown but kept in the API' do
      tampered = <<~MD
        ### 1. `capability_gate`
        ### 2. `renamed_runtime_context`
        ### 3. `plugin_loader`
        ### 4. `theme_tokens`
        ### 5. `data_export`
      MD

      documented = described_class.documented_points(tampered)
      implemented = described_class.implemented_points

      missing = documented - implemented
      undocumented = implemented - documented

      expect(missing).to include('renamed_runtime_context')
      expect(undocumented).to include('runtime_context')
    end

    it 'flags an extension point that was removed from the markdown but kept in the API' do
      tampered = <<~MD
        ### 1. `capability_gate`
        ### 2. `plugin_loader`
        ### 3. `theme_tokens`
        ### 4. `data_export`
      MD

      documented = described_class.documented_points(tampered)
      implemented = described_class.implemented_points

      undocumented = implemented - documented
      expect(undocumented).to include('runtime_context')
    end
  end
end
