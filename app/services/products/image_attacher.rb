# frozen_string_literal: true

module Products
  # EVO-2226 (Frente B): attaches images arriving on a product create/update,
  # from raw multipart uploads or ActiveStorage signed_ids. Returns what it
  # refused — a file dropped in silence reads as "saved, and the image vanished".
  class ImageAttacher
    Rejection = Struct.new(:filename, :reason, keyword_init: true) do
      def as_json(*)
        { filename: filename, reason: reason }
      end
    end

    def initialize(product)
      @product = product
      @slots = ImagePolicy.remaining_slots(product)
      @rejected = []
    end

    def call(items)
      Array(items).each { |item| process(item) }
      @rejected
    end

    private

    def process(item)
      item.respond_to?(:read) ? attach_upload(item) : attach_signed_id(item)
    end

    def attach_upload(file)
      reason = rejection_for(file)
      return reject(file.original_filename, reason) if reason

      @product.images.attach(
        io: file.open,
        filename: file.original_filename,
        content_type: file.content_type
      )
      @slots -= 1
    end

    def attach_signed_id(signed_id)
      return reject(nil, 'too_many') if @slots.zero?

      blob = ActiveStorage::Blob.find_signed(signed_id)
      return if blob.blank?

      @product.images.attach(blob)
      @slots -= 1
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      reject(nil, 'invalid_signature')
    end

    def rejection_for(file)
      size = file.size.to_i

      return 'too_many' if @slots.zero?
      return 'invalid_type' unless ImagePolicy.allowed_type?(file.content_type)
      return 'empty' unless size.positive?
      return 'too_large' if size > ImagePolicy::MAX_BYTES

      nil
    end

    def reject(filename, reason)
      @rejected << Rejection.new(filename: filename, reason: reason)
    end
  end
end
