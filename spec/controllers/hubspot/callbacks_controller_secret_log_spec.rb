# frozen_string_literal: true

require 'rails_helper'

# EVO-2250, collateral of the credential survey.
#
# The callback logged `token_params.inspect` at INFO. That hash carries the
# app's `client_secret` AND the one-time authorization `code`, so the
# installation secret was written in cleartext to any log sink, on every OAuth
# connection.
# rubocop:disable RSpec/DescribeClass -- this asserts on the SOURCE of a
# controller, not on its behaviour: the leak is a log line, and rendering it
# through a request spec would need the whole OAuth round trip.
RSpec.describe 'Hubspot callback secret logging' do
  let(:source) { Rails.root.join('app/controllers/hubspot/callbacks_controller.rb').read }

  # Rendering the whole hash is the defect; reading one PUBLIC field out of it
  # (the redirect_uri) is fine and is what keeps the log line useful.
  it 'never renders the token exchange params hash into a log line' do
    offending = source.lines.each_with_index.select do |line, _|
      line.include?('logger') && line.match?(/token_params(\.inspect|\.to_json)/)
    end

    expect(offending).to be_empty,
                         "the params hash reaches the log: #{offending.map { |l, i| "line #{i + 1}: #{l.strip}" }}"
  end

  it 'never logs the secret-bearing fields of the exchange' do
    offending = source.lines.select do |line|
      line.include?('logger') && line.match?(/token_params\[:(client_secret|code)\]/)
    end

    expect(offending).to be_empty, "a secret field reaches the log: #{offending.map(&:strip)}"
  end

  it 'does not interpolate the client secret into any log line' do
    offending = source.lines.grep(/logger.*client_secret/i)

    expect(offending).to be_empty, "client_secret reaches the log: #{offending.map(&:strip)}"
  end
end
# rubocop:enable RSpec/DescribeClass
