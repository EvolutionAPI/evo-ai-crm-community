# frozen_string_literal: true

module Products
  # EVO-2226: image ingestion is third-party network I/O and must not run inside
  # the /products/bulk request. A batch can carry MAX_ITEMS (500) products with
  # MAX_PER_IMPORT URLs each — done inline that is thousands of sequential
  # fetches holding the request open long past any proxy timeout, and the client
  # would read a 504 for an import that actually committed.
  #
  # Products are already saved when this runs, so anything that fails here costs
  # the image and nothing else.
  class AttachRemoteImagesJob < ApplicationJob
    queue_as :low

    def perform(product_id, image_urls)
      product = Product.find_by(id: product_id)
      return if product.nil?

      Products::ImageIngestor.attach_all(product, image_urls)
    end
  end
end
