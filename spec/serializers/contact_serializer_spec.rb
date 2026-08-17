# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContactSerializer do
  describe '.serialize' do
    let(:contact) { Contact.create!(name: 'Jane Doe', email: "jane-#{SecureRandom.hex(4)}@example.com") }

    it 'emits thumbnail with the contact avatar URL when present (EVO-1012)' do
      allow(contact).to receive(:avatar_url).and_return('https://cdn.example.com/uploads/avatar.jpg')

      result = described_class.serialize(contact, include_labels: false)

      expect(result).to have_key('thumbnail')
      expect(result['thumbnail']).to eq('https://cdn.example.com/uploads/avatar.jpg')
    end

    it 'returns nil thumbnail (not empty string) so the FE skips rendering <img src="">' do
      allow(contact).to receive(:avatar_url).and_return('')

      result = described_class.serialize(contact, include_labels: false)

      expect(result).to have_key('thumbnail')
      expect(result['thumbnail']).to be_nil
    end

    it 'returns nil thumbnail when contact has no avatar attached (real Avatarable path)' do
      result = described_class.serialize(contact, include_labels: false)

      expect(result).to have_key('thumbnail')
      expect(result['thumbnail']).to be_nil
    end
  end

  # A contact's chip carries the tag name and the colour of the Label behind it.
  # Unlike the conversation payload, a tag with no matching Label is kept and
  # rendered in the default colour rather than dropped — losing the chip would
  # hide a tagging the operator can see in the contact's own label list.
  describe '.serialize with include_labels' do
    let!(:urgent) { Label.create!(title: 'urgente', color: '#ff0000', show_on_sidebar: true) }

    def tagged_contact(*titles)
      contact = Contact.create!(name: 'Tagged', email: "tagged-#{SecureRandom.hex(4)}@example.com")
      contact.label_list = titles
      contact.save!
      contact
    end

    # Only the `labels` table is counted: preloading the taggings themselves is a
    # separate concern, and conflating the two hides which query is per-contact.
    def count_label_table_queries
      count = 0
      subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        next if payload[:name].to_s.in?(%w[SCHEMA TRANSACTION])

        count += 1 if payload[:sql].to_s.match?(/from\s+"?labels"?/i)
      end
      yield
      count
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'emits the tag name with the colour of the label behind it' do
      result = described_class.serialize(tagged_contact('urgente'), include_labels: true)

      expect(result['labels']).to eq([{ name: 'urgente', color: '#ff0000' }])
    end

    it 'keeps a tag that matches no label, in the default colour' do
      result = described_class.serialize(tagged_contact('sumiu'), include_labels: true)

      expect(result['labels']).to eq([{ name: 'sumiu', color: '#1f93ff' }])
    end

    it 'resolves the whole collection in a single query against labels' do
      contacts = [tagged_contact('urgente'), tagged_contact('urgente')]

      queries = count_label_table_queries do
        described_class.serialize_collection(contacts, include_labels: true)
      end

      expect(queries).to eq(1)
    end
  end
end
