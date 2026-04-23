# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Conversations::FilterService do
  describe '#conversations' do
    it 'orders by last_activity_at desc and paginates' do
      user = instance_double(User)
      service = described_class.new({}, user)

      relation = double('Relation')
      service.instance_variable_set(:@conversations, relation)

      expect(relation).to receive(:sort_on_last_activity_at).with(:desc).and_return(relation)
      expect(relation).to receive(:page).with(1).and_return(relation)

      service.conversations
    end
  end

  describe '#filter_payload (key aliasing)' do
    let(:user) { instance_double(User) }
    let(:rows) do
      [{ 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => ['open'], 'query_operator' => nil }]
    end

    it 'reads rows from :payload (upstream Chatwoot contract)' do
      service = described_class.new({ payload: rows }, user)
      expect(service.send(:filter_payload)).to eq(rows)
    end

    it 'reads rows from :filters as a compat alias for the evo frontend' do
      service = described_class.new({ filters: rows }, user)
      expect(service.send(:filter_payload)).to eq(rows)
    end

    it 'returns an empty array when neither key is provided, avoiding NoMethodError' do
      service = described_class.new({}, user)
      expect(service.send(:filter_payload)).to eq([])
      expect { service.send(:validate_query_operator) }.not_to raise_error
    end
  end

  describe '#query_builder (empty-clause handling)' do
    let(:user) { instance_double(User) }

    it 'drops rows whose built clause is empty without desyncing the operator of the next row' do
      rows = [
        { 'attribute_key' => 'a', 'filter_operator' => 'equal_to', 'values' => ['x'], 'query_operator' => nil },
        { 'attribute_key' => 'b', 'filter_operator' => 'equal_to', 'values' => ['y'], 'query_operator' => 'OR' },
        { 'attribute_key' => 'c', 'filter_operator' => 'equal_to', 'values' => ['z'], 'query_operator' => 'AND' }
      ]
      service = described_class.new({ filters: rows }, user)

      allow(service).to receive(:build_condition_query) do |_m, _q, idx|
        # Middle clause is empty (simulates a handler that returned '' on a
        # path that bypasses the InvalidAttribute guard). Last clause still
        # carries its trailing operator suffix to exercise the strip regex.
        ['c0', '', 'c2 AND'][idx]
      end

      relation = double('Relation')
      allow(service).to receive(:base_relation).and_return(relation)
      expect(relation).to receive(:where).with('c0 AND c2', anything).and_return(relation)

      service.send(:query_builder, {})
    end
  end
end
