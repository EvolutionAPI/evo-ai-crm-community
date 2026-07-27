# frozen_string_literal: true

module Products
  # EVO-2226: a bulk import can carry 500 products with several image URLs each —
  # fetching them inline would hold the request past any proxy timeout, on an
  # import that already committed. Products are saved before this runs.
  class AttachRemoteImagesJob < ApplicationJob
    queue_as :low

    def perform(product_id, image_urls)
      product = Product.find_by(id: product_id)
      return if product.nil?

      Products::ImageIngestor.attach_all(product, image_urls)
    end
  end
end
