# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Contacts::FilterService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }

  def cond(key, operator, values)
    [{ 'attribute_key' => key, 'filter_operator' => operator, 'values' => values, 'query_operator' => nil }]
  end

  def run(rows)
    params = ActionController::Parameters.new(payload: rows).permit!
    described_class.new(nil, user, params).perform
  end

  describe 'country_code filter (EVO-1849 M1)' do
    it 'matches on the top-level contacts.country_code column, case-insensitively' do
      match = Contact.create!(name: 'C', email: "c-#{SecureRandom.hex(4)}@t.com")
      match.update_column(:country_code, 'br')
      other = Contact.create!(name: 'D', email: "d-#{SecureRandom.hex(4)}@t.com")
      other.update_column(:country_code, 'us')

      result = run(cond('country_code', 'equal_to', ['BR']))

      expect(result[:contacts]).to include(match)
      expect(result[:count]).to eq(1)
    end
  end

  describe 'company filter (EVO-1849 B1 — removed; association-based filter tracked as follow-up)' do
    it 'is no longer a valid contact filter attribute' do
      expect { run(cond('company', 'contains', ['acme'])) }
        .to raise_error(CustomExceptions::CustomFilter::InvalidAttribute)
    end
  end
end
