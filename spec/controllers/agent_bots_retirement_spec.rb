# frozen_string_literal: true

require 'rails_helper'

# Source-level guards, because the defects are "a line that is still there":
# a request spec would need the whole bot CRUD, which this branch does not have.
# rubocop:disable RSpec/DescribeClass -- these assert on SOURCE lines: the defects are "a line still there", and a request spec would need the bot CRUD this branch does not have
RSpec.describe 'Agent bot retirement, source guards' do
  it 'no longer accepts :api_key in the permitted params (2.7 AC1)' do
    source = Rails.root.join('app/controllers/api/v1/agent_bots_controller.rb').read

    permitted = source[/def permitted_params.*?\n  end/m]
    expect(permitted).to be_present

    expect(permitted).not_to include(':api_key'),
                             'the inline key can still be registered through the API'
    expect(permitted).to include(':credential_id'),
                         'the vault reference must remain writable'
  end

  # High 4: two of the six consumption points kept `if api_key.present?` in front
  # of the resolver, so a bot with a credential_id and no inline key went out with
  # NO X-API-Key / NO Authorization at all.
  {
    'app/services/agent_bots/http_request_service.rb' => 'X-API-Key',
    'app/services/facebook/moderation/response_generator_service.rb' => 'Authorization'
  }.each do |path, header|
    it "does not gate the #{header} header on the inline key (#{File.basename(path)})" do
      source = Rails.root.join(path).read

      # The defect is the BOT's inline column gating the header. A guard on the
      # resolved local (`api_key.present?` after resolution) is correct and must
      # not trip this.
      offending = source.lines.each_with_index.select do |line, _|
        line.match?(/(@?agent_bot|@agent_bot)\.api_key/) && !line.strip.start_with?('#')
      end

      expect(offending).to be_empty,
                           "the inline-key gate is still there, so a vault-only bot sends no #{header}: " \
                           "#{offending.map { |l, i| "line #{i + 1}: #{l.strip}" }}"
    end
  end

  # High 14: a key shorter than ~21 chars was logged in full by the
  # first-11-plus-last-10 fragment.
  it 'never logs a fragment of the bot key' do
    source = Rails.root.join('app/services/agent_bots/http_request_service.rb').read

    offending = source.lines.grep(/logger.*api_key\[/)

    expect(offending).to be_empty, "the key still reaches the log: #{offending.map(&:strip)}"
  end
end
# rubocop:enable RSpec/DescribeClass
