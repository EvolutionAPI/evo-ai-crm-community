# frozen_string_literal: true

module Products
  # What counts as an acceptable product image. Shared by ImageAttacher (manual upload)
  # and ImageIngestor (import) so the two cannot drift.
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

    # Counted from the database: attachments accumulate across requests, and the cap is
    # per product, not per upload.
    def remaining_slots(product)
      [MAX_PER_PRODUCT - product.images.count, 0].max
    end
  end
end
