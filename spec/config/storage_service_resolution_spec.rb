# frozen_string_literal: true

require 'rails_helper'

# EVO-2095 regression guard. Storage is boot infrastructure: the service AND its
# credentials must be ENV-driven and deterministic across processes (puma,
# sidekiq, runners). Reading them from the DB during boot config made the
# `active_storage_blob` load hook fire before the service was assigned, so the
# service "froze" as DiskService in some processes -> attachments landed on the
# container's ephemeral disk and were lost on redeploy.
#
# This is a source-level guard (the resolution runs at boot in RAILS_ENV=production
# and cannot be exercised by the test-env suite). It fails if anyone re-introduces
# the DB-first resolution.
RSpec.describe 'Storage config resolution (EVO-2095)' do
  let(:production_rb) { Rails.root.join('config/environments/production.rb').read }
  let(:storage_yml)   { Rails.root.join('config/storage.yml').read }

  it 'resolves active_storage.service from the ENV (not GlobalConfigService) in production' do
    service_line = production_rb.lines.find do |line|
      line.include?('config.active_storage.service') && !line.strip.start_with?('#')
    end

    expect(service_line).to be_present
    expect(service_line).to include("ENV.fetch('ACTIVE_STORAGE_SERVICE'")
    expect(service_line).not_to include('GlobalConfigService')
  end

  it 'resolves s3_compatible credentials ENV-first (load_env_first), never DB-first (.load)' do
    s3_block = storage_yml[/^s3_compatible:.*?(?=^\S|\z)/m]

    expect(s3_block).to be_present
    expect(s3_block).to include('load_env_first')
    # GlobalConfigService.load( ... ) is the DB-first call; load_env_first( does not match it.
    expect(s3_block).not_to match(/GlobalConfigService\.load\(/)
  end
end
