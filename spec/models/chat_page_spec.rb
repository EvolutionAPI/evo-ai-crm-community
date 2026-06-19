# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatPage, type: :model do
  let(:web_widget) { Channel::WebWidget.create!(website_url: 'https://chat.example.com') }
  let!(:inbox) { Inbox.create!(name: 'Chat Inbox', channel: web_widget) }

  def build_page(attrs = {})
    ChatPage.new({ title: 'Atendimento', website_token: web_widget.website_token }.merge(attrs))
  end

  describe 'slug generation' do
    it 'derives a slug from the title on create' do
      page = build_page(title: 'Fale Conosco')
      page.save!
      expect(page.slug).to eq('fale-conosco')
    end

    it 'disambiguates colliding slugs' do
      build_page(title: 'Dup').save!
      second = build_page(title: 'Dup')
      second.save!
      expect(second.slug).to eq('dup-2')
    end
  end

  describe 'validations' do
    it 'requires a website_token that matches an existing web widget' do
      page = build_page(website_token: 'nonexistent-token')
      expect(page).not_to be_valid
      expect(page.errors[:website_token].join).to include('does not match')
    end
  end

  describe '#display_title' do
    it 'falls back to the widget inbox name when no title' do
      page = build_page(title: nil)
      page.save!
      expect(page.display_title).to eq(inbox.name)
    end
  end
end
