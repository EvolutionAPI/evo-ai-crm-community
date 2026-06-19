# frozen_string_literal: true

# == Schema Information
#
# Table name: chat_pages
#
#  id            :uuid             not null, primary key
#  appearance    :jsonb            not null
#  description   :text
#  published     :boolean          default(FALSE), not null
#  slug          :string(255)      not null
#  title         :string(255)
#  website_token :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#
# Indexes
#
#  index_chat_pages_on_published      (published)
#  index_chat_pages_on_slug           (slug) UNIQUE
#  index_chat_pages_on_website_token  (website_token)
#
# A public, self-contained chat page (B14.03). Mounts the existing site-widget
# SDK by `website_token` so a tenant can offer chat at `/chat/:slug` without
# embedding the widget on their own site. Single-tenant in Community.
class ChatPage < ApplicationRecord
  before_validation :generate_slug, on: :create

  validates :slug, presence: true, uniqueness: true, length: { maximum: 255 },
                   format: { with: /\A[a-z0-9\-]+\z/, message: 'must be lowercase alphanumeric with dashes' }
  validates :website_token, presence: true
  validate :website_token_matches_widget

  scope :published, -> { where(published: true) }

  # The web-widget channel this page wraps (resolved by website_token).
  def web_widget
    @web_widget ||= Channel::WebWidget.find_by(website_token: website_token)
  end

  # Public heading: explicit title, else the widget's inbox name.
  def display_title
    title.presence || web_widget&.inbox&.name
  end

  private

  def website_token_matches_widget
    return if website_token.blank?

    errors.add(:website_token, 'does not match an existing web widget') unless Channel::WebWidget.exists?(website_token: website_token)
  end

  def generate_slug
    return if slug.present?

    base = title.to_s.parameterize
    base = "chat-#{SecureRandom.hex(4)}" if base.blank?

    candidate = base
    suffix = 2
    while ChatPage.exists?(slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end

    self.slug = candidate
  end
end
