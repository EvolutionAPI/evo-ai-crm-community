# frozen_string_literal: true

require 'rails_helper'
require 'evo_extension_points'
require 'rake'

RSpec.describe 'evo_extension_points:check_contract rake task', type: :task do
  let(:task) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('evo_extension_points:check_contract')
    Rake::Task['evo_extension_points:check_contract']
  end

  before { task.reenable }

  def stub_extension_points_md(markdown)
    md_path = instance_double(Pathname, exist?: true, read: markdown, to_s: 'EXTENSION_POINTS.md')
    allow(Rails.root).to receive(:join).with('EXTENSION_POINTS.md').and_return(md_path)
  end

  context 'when documented and implemented points match' do
    it 'exits cleanly (no SystemExit)' do
      expect { task.invoke }.to output(/OK — 5 extension point\(s\) documented and implemented/).to_stdout
    end
  end

  context 'when an extension point declared in the markdown has no matching module' do
    before do
      stub_extension_points_md(<<~MD)
        ### 1. `feature_gate`
        ### 2. `tenant_context`
        ### 3. `plugin_loader`
        ### 4. `theme_tokens`
        ### 5. `data_export`
        ### 6. `ghost_extension_point`
      MD
    end

    it 'aborts with the literal AC3 wording naming the missing point' do
      expect { task.invoke }
        .to raise_error(SystemExit)
        .and output(/Breaking change in extension point ghost_extension_point — needs major version bump \+ deprecation window/).to_stderr
    end
  end

  context 'when a module exists under EvoExtensionPoints but is not documented' do
    before do
      stub_extension_points_md(<<~MD)
        ### 1. `feature_gate`
        ### 2. `tenant_context`
        ### 3. `plugin_loader`
        ### 4. `theme_tokens`
      MD
    end

    it 'aborts identifying the undocumented module name' do
      expect { task.invoke }
        .to raise_error(SystemExit)
        .and output(/Undocumented extension point\(s\) detected.*data_export/m).to_stderr
    end
  end
end
