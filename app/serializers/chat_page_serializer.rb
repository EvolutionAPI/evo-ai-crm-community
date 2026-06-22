# frozen_string_literal: true

# ChatPageSerializer - admin serialization of a ChatPage (B14.08).
#
# Plain Ruby module matching the convention used by CrmFormSerializer /
# ProductSerializer in this app.
module ChatPageSerializer
  extend self

  def serialize(page)
    {
      id: page.id,
      slug: page.slug,
      title: page.title,
      display_title: page.display_title,
      description: page.description,
      appearance: page.appearance || {},
      website_token: page.website_token,
      widget_inbox_name: page.web_widget&.inbox&.name,
      published: page.published,
      public_path: "/chat/#{page.slug}",
      created_at: page.created_at&.iso8601,
      updated_at: page.updated_at&.iso8601
    }
  end

  def serialize_collection(pages)
    return [] unless pages

    pages.map { |page| serialize(page) }
  end
end
