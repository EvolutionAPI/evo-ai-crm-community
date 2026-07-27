# frozen_string_literal: true

# Bulk-imports products in a single ACID transaction (EVO-1555 S1).
#
# Public entry point: `Products::BulkImporter.new(items).call`.
# Raises Products::BulkImporter::BulkImportError carrying a positional
# errors payload when any item fails — the whole batch is rolled back.
module Products
  class BulkImporter
    MAX_ITEMS = 500
    SCALAR_ATTRS = %i[
      name slug kind description sku
      default_price currency purchase_url
      status stock_quantity
    ].freeze

    class BulkImportError < StandardError
      attr_reader :errors_payload

      def initialize(errors_payload)
        @errors_payload = errors_payload
        super('Bulk import failed')
      end
    end

    # EVO-1736 S1.1 — dry-run runs the same transaction, then raises
    # ActiveRecord::Rollback. Result carries the would-be-created preview
    # and any per-item errors, so callers always get 200 with a structured
    # report instead of the 422-on-error semantics of the real path.
    DryRunResult = Struct.new(:would_create, :errors, keyword_init: true)

    def initialize(items, dry_run: false)
      @items = items
      @dry_run = dry_run
    end

    def call
      pre_errors = pre_validate_items
      if pre_errors.any?
        return DryRunResult.new(would_create: [], errors: pre_errors) if @dry_run

        raise BulkImportError, pre_errors
      end

      created, errors_acc = run_transaction
      return build_dry_run_result(created, errors_acc) if @dry_run

      # Images are fetched from remote URLs — queued after the transaction commits
      # so slow/failed downloads neither hold the lock nor roll back a saved
      # product, and never make the client wait on a third-party CDN.
      enqueue_remote_images(created)

      created.map { |_index, product, _labels, _urls| product }
    end

    private

    def run_transaction
      created = []
      errors_acc = []

      ActiveRecord::Base.transaction do
        @items.each_with_index { |raw_item, index| import_one(raw_item, index, created, errors_acc) }
        if @dry_run
          raise ActiveRecord::Rollback
        elsif errors_acc.any?
          raise BulkImportError, errors_acc
        end
      end

      [created, errors_acc]
    end

    # First pass: collects all type errors AND intra-batch SKU conflicts together,
    # so the client gets the full picture in a single 422 instead of finding the
    # next error only after fixing the previous one.
    def pre_validate_items
      errors = []
      seen_skus = {}

      @items.each_with_index do |raw_item, index|
        unless hash_like?(raw_item)
          errors << { index: index, sku: nil, errors: { base: ['item must be a JSON object'] } }
          next
        end

        sku = raw_item[:sku]
        next if sku.blank?

        if seen_skus.key?(sku)
          errors << { index: index, sku: sku, errors: { sku: ['duplicated within batch'] } }
        else
          seen_skus[sku] = index
        end
      end

      errors
    end

    def import_one(raw_item, index, created, errors_acc)
      scalar_attrs, labels, image_urls = item_params(raw_item)
      product = Product.new(scalar_attrs)

      unless product.save
        errors_acc << { index: index, sku: scalar_attrs[:sku], errors: product.errors.as_json }
        return
      end

      product.update_labels(labels) if labels.present? && !@dry_run
      created << [index, product, labels, image_urls]
    end

    def item_params(raw_item)
      params_obj = raw_item.is_a?(ActionController::Parameters) ? raw_item : ActionController::Parameters.new(raw_item.to_h)
      permitted = params_obj.permit(*SCALAR_ATTRS, metadata: {}).to_h.symbolize_keys

      # Normalise blank SKU to nil so the partial unique index (WHERE sku IS NOT NULL)
      # treats "no SKU" rows as truly absent — otherwise two items with sku: "" raise
      # PG::UniqueViolation outside the AR validation layer.
      permitted[:sku] = nil if permitted[:sku].blank?

      labels_raw = params_obj[:labels]
      labels = labels_raw.present? ? Array(labels_raw).map(&:to_s) : nil

      # EVO-2226: image URLs (from the import connectors) ride alongside the item
      # but are not product columns — enqueued post-commit on a real import.
      image_urls_raw = params_obj[:image_urls]
      image_urls = image_urls_raw.present? ? Array(image_urls_raw).map(&:to_s) : nil

      [permitted, labels, image_urls]
    end

    def hash_like?(item)
      item.is_a?(Hash) || item.is_a?(ActionController::Parameters)
    end

    # EVO-2226: best-effort and out-of-band. A blocked/oversized/failed image is
    # logged and skipped by the ingestor — the product is already saved, so the
    # image is the only thing at stake.
    def enqueue_remote_images(created)
      created.each do |_index, product, _labels, image_urls|
        next if image_urls.blank?

        Products::AttachRemoteImagesJob.perform_later(
          product.id, image_urls.first(Products::ImagePolicy::MAX_PER_IMPORT)
        )
      end
    end

    def build_dry_run_result(created, errors)
      DryRunResult.new(
        would_create: created.map do |index, product, labels, _urls|
          entry = { index: index, sku: product.sku, name: product.name }
          entry[:labels] = labels if labels.present?
          entry
        end,
        errors: errors
      )
    end
  end
end
