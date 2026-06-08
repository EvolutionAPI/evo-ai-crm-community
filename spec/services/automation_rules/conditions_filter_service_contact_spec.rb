# frozen_string_literal: true

require 'rails_helper'

# EVO-1642: ConditionsFilterService evaluates contact-only rules WITHOUT a
# conversation (base_relation falls back to Contact.where(id:)). It is now the
# SOLE evaluator for the contact path — the hand-rolled Ruby evaluator it
# replaced was deleted in phase 2. This spec is its regression net: it asserts
# the correct boolean for every contact operator in the whitelist
# (AutomationRuleListener#rule_has_only_contact_conditions?) using the operator
# sets in lib/filters/filter_keys.yml (the only combos the frontend produces).
RSpec.describe AutomationRules::ConditionsFilterService do
  let!(:vip) { Label.create!(title: "vip-#{SecureRandom.hex(3)}", color: '#abcdef') }
  let!(:gold) { Label.create!(title: "gold-#{SecureRandom.hex(3)}", color: '#ffd700') }
  let(:contact) do
    c = Contact.create!(name: 'Jane', email: "jane-#{SecureRandom.hex(4)}@test.com", phone_number: "+55#{rand(10**10)}")
    c.update!(additional_attributes: { 'city' => 'SP', 'company' => 'Acme', 'country_code' => 'BR' }, label_list: [vip.title])
    Current.reset
    c.reload
  end
  let(:bare_contact) { Contact.create!(name: 'Bare', email: "bare-#{SecureRandom.hex(4)}@test.com", phone_number: "+55#{rand(10**10)}") }
  # email is NULL and there are no additional_attributes (no 'city' key).
  let(:null_contact) { Contact.create!(name: 'NoEmail', email: nil, phone_number: "+55#{rand(10**10)}") }

  after { Current.reset }

  def build_rule(conditions)
    rule = AutomationRule.new(
      name: "rule-#{SecureRandom.hex(4)}", event_name: 'contact_updated', active: true, mode: 'simple',
      conditions: conditions, actions: []
    )
    rule.save!(validate: false)
    rule
  end

  # Evaluates the rule through the (now sole) SQL evaluator and asserts the
  # expected boolean for the given contact operator.
  def expect_match(conditions, expected:, changed: {}, on: nil)
    target = on || contact
    rule = build_rule(conditions)
    sql = described_class.new(rule, nil, contact: target.reload, changed_attributes: changed).perform
    expect(sql).to eq(expected), "sql evaluator: expected #{expected}, got #{sql.inspect}"
  end

  describe 'text attributes (name/email/phone)' do
    it('name equal_to matches')        { expect_match([cond('name', 'equal_to', ['Jane'])], expected: true) }
    it('name equal_to mismatches')     { expect_match([cond('name', 'equal_to', ['Bob'])], expected: false) }
    it('name not_equal_to matches')    { expect_match([cond('name', 'not_equal_to', ['Bob'])], expected: true) }
    it('email contains matches')       { expect_match([cond('email', 'contains', ['@test.com'])], expected: true) }
    it('name does_not_contain')        { expect_match([cond('name', 'does_not_contain', ['Bob'])], expected: true) }
    it('phone_number starts_with')     { expect_match([cond('phone_number', 'starts_with', ['+55'])], expected: true) }
  end

  describe 'additional_attributes (city/company/country_code)' do
    it('city equal_to matches')        { expect_match([cond('city', 'equal_to', ['SP'])], expected: true) }
    it('company contains matches')     { expect_match([cond('company', 'contains', ['Acm'])], expected: true) }
    it('country_code not_equal_to')    { expect_match([cond('country_code', 'not_equal_to', ['US'])], expected: true) }
  end

  describe 'blocked (boolean)' do
    it('blocked equal_to false')       { expect_match([cond('blocked', 'equal_to', ['false'])], expected: true) }
    it('blocked equal_to true (miss)') { expect_match([cond('blocked', 'equal_to', ['true'])], expected: false) }
  end

  describe 'labels' do
    it 'equal_to is any-of (matches when the contact has ANY listed label)' do
      expect_match([cond('labels', 'equal_to', [vip.id, gold.id])], expected: true)
    end
    it 'not_equal_to matches only when the contact has NONE of the listed labels' do
      expect_match([cond('labels', 'not_equal_to', [gold.id])], expected: true)
      expect_match([cond('labels', 'not_equal_to', [vip.id])], expected: false)
    end
    it 'is_present matches a contact with labels, not a bare contact' do
      expect_match([cond('labels', 'is_present', [])], expected: true)
      expect_match([cond('labels', 'is_present', [])], expected: false, on: bare_contact)
    end
    it 'is_not_present matches a bare contact, not a labelled one' do
      expect_match([cond('labels', 'is_not_present', [])], expected: true, on: bare_contact)
      expect_match([cond('labels', 'is_not_present', [])], expected: false)
    end
  end

  # EVO-1642 regression guard: the retired Ruby evaluator treated a nil/absent
  # value as SATISFYING negative operators; SQL's NULL three-valued logic does
  # not. contact_predicate restores that by making negatives NULL-inclusive.
  describe 'negative operators on null / absent values' do
    it('not_equal_to matches a null standard column')      { expect_match([cond('email', 'not_equal_to', ['x@y.com'])], expected: true, on: null_contact) }
    it('does_not_contain matches a null standard column')   { expect_match([cond('email', 'does_not_contain', ['spam'])], expected: true, on: null_contact) }
    it('not_equal_to matches an absent additional attr')    { expect_match([cond('city', 'not_equal_to', ['NYC'])], expected: true, on: null_contact) }
    it('does_not_contain matches an absent additional attr') { expect_match([cond('city', 'does_not_contain', ['x'])], expected: true, on: null_contact) }
    it('not_equal_to still excludes a matching value')      { expect_match([cond('name', 'not_equal_to', ['NoEmail'])], expected: false, on: null_contact) }
  end

  describe 'attribute_changed transitions' do
    it 'scalar boolean transition (blocked false -> true)' do
      expect_match([cond('blocked', 'attribute_changed', { 'from' => ['false'], 'to' => ['true'] })],
                    changed: { 'blocked' => [false, true] }, expected: true)
    end
    it 'scalar transition mismatch (opposite direction)' do
      expect_match([cond('blocked', 'attribute_changed', { 'from' => ['true'], 'to' => ['false'] })],
                    changed: { 'blocked' => [false, true] }, expected: false)
    end
    it 'scalar empty from is a wildcard' do
      expect_match([cond('blocked', 'attribute_changed', { 'from' => [], 'to' => ['true'] })],
                    changed: { 'blocked' => [false, true] }, expected: true)
    end
    it 'labels transition when the requested label was added' do
      expect_match([cond('labels', 'attribute_changed', { 'from' => [], 'to' => [vip.id] })],
                    changed: { 'label_list' => [[], [vip.title]] }, expected: true)
    end
    it 'labels transition when the watched label was NOT in the diff' do
      expect_match([cond('labels', 'attribute_changed', { 'from' => [], 'to' => [gold.id] })],
                    changed: { 'label_list' => [[], [vip.title]] }, expected: false)
    end
  end

  describe 'no conditions' do
    it('an empty condition set matches (vacuous truth)') { expect_match([], expected: true) }
  end

  def cond(key, operator, values, query_operator = nil)
    { 'attribute_key' => key, 'filter_operator' => operator, 'values' => values, 'query_operator' => query_operator }
  end
end
