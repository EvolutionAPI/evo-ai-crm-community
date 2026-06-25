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

  describe 'company filter (EVO-1887 — association-based)' do
    let(:company) { Contact.create!(name: 'Acme', email: "acme-#{SecureRandom.hex(4)}@t.com", type: 'company') }
    let(:other_company) { Contact.create!(name: 'Globex', email: "globex-#{SecureRandom.hex(4)}@t.com", type: 'company') }

    def person_with_company(company_record)
      person = Contact.create!(name: 'P', email: "p-#{SecureRandom.hex(4)}@t.com", type: 'person')
      person.contact_companies.create!(company_id: company_record.id)
      person
    end

    it 'returns contacts associated with the selected company via contact_companies (equal_to)' do
      match = person_with_company(company)
      person_with_company(other_company)

      result = run(cond('company', 'equal_to', [company.id]))

      expect(result[:contacts]).to include(match)
      expect(result[:count]).to eq(1)
    end

    it 'excludes contacts associated with the selected company (not_equal_to)' do
      excluded = person_with_company(company)
      kept = person_with_company(other_company)

      result = run(cond('company', 'not_equal_to', [company.id]))

      expect(result[:contacts]).to include(kept)
      expect(result[:contacts]).not_to include(excluded)
    end

    it 'includes contacts with no company association in not_equal_to results' do
      excluded = person_with_company(company)
      no_company = Contact.create!(name: 'NoCo', email: "noco-#{SecureRandom.hex(4)}@t.com", type: 'person')

      result = run(cond('company', 'not_equal_to', [company.id]))

      expect(result[:contacts]).to include(no_company)
      expect(result[:contacts]).not_to include(excluded)
    end

    it 'matches contacts having any company association (is_present)' do
      with_company = person_with_company(company)
      Contact.create!(name: 'NoCompany', email: "nc-#{SecureRandom.hex(4)}@t.com", type: 'person')

      result = run(cond('company', 'is_present', []))

      expect(result[:contacts]).to include(with_company)
    end
  end
end
