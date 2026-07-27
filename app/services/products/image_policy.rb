# frozen_string_literal: true

module Products
  # EVO-2226: single source of truth for an acceptable product image. Enforced by
  # both entry points — Products::ImageAttacher (manual upload) and
  # Products::ImageIngestor (import) — so the two can't drift apart.
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

    # How many more images `product` can take. Counted from the database because
    # attachments accumulate across requests — the cap is per product, not per upload.
    def remaining_slots(product)
      [MAX_PER_PRODUCT - product.images.count, 0].max
    end
  end
end
