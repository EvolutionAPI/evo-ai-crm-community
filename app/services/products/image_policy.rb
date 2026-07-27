# frozen_string_literal: true

module Products
  # EVO-2226: single source of truth for what counts as an acceptable product
  # image. Both entry points enforce it — the manual upload
  # (Products::ImageAttacher, behind ProductsController#create/#update) and the
  # import (Products::ImageIngestor) — so the two paths can't drift apart.
  module ImagePolicy
    MAX_BYTES = 5 * 1024 * 1024 # per image
    MAX_PER_PRODUCT = 10        # ceiling of images attached to one product, all paths
    MAX_PER_IMPORT = 5          # URLs worth downloading per imported product

    ALLOWED_TYPES = %w[image/jpeg image/png image/webp image/gif image/avif].freeze
    EXTENSIONS = {
      'image/jpeg' => '.jpg', 'image/png' => '.png', 'image/webp' => '.webp',
      'image/gif' => '.gif', 'image/avif' => '.avif'
    }.freeze

    module_function

    def allowed_type?(content_type)
      ALLOWED_TYPES.include?(content_type.to_s.split(';').first.to_s.strip.downcase)
    end

    def extension_for(content_type)
      EXTENSIONS.fetch(content_type.to_s.downcase, '')
    end

    # How many more images `product` can still take. Counted from the database
    # rather than tracked in memory because a product reaches this from several
    # requests over its lifetime — the cap is per product, not per upload.
    def remaining_slots(product)
      [MAX_PER_PRODUCT - product.images.count, 0].max
    end
  end
end
