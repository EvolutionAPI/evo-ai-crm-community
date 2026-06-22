# frozen_string_literal: true

# Anonymous, public chat-page endpoint (B14.03).
#
# Inherits directly from PublicController (no API key): the page is resolved by
# its public slug and returns the widget `website_token` (public by design — it
# is the same token printed in the widget embed script) plus appearance, so the
# frontend can mount the existing widget SDK. Only published pages respond.
class Public::Api::V1::ChatPagesController < PublicController
  def show
    chat_page = ChatPage.published.find_by(slug: params[:slug])

    return render json: { success: false, error: 'Chat page not found' }, status: :not_found unless chat_page

    render json: {
      success: true,
      data: {
        slug: chat_page.slug,
        title: chat_page.display_title,
        description: chat_page.description,
        appearance: chat_page.appearance || {},
        website_token: chat_page.website_token
      }
    }
  end
end
