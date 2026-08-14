# frozen_string_literal: true

# ApiResponseHelper - Standard API Response Format
#
# This module provides standardized methods for API responses following the
# official API standard defined in API_RESPONSE_STANDARD.md
#
# All responses follow the structure:
# {
#   success: true/false,
#   data: {...} or [...],
#   meta: { timestamp: "ISO8601", ... },
#   message: "Optional message",
#   error: { code: "ERROR_CODE", message: "...", details: [...] } # only on errors
# }
#
# Usage:
#   include ApiResponseHelper
#
#   def index
#     success_response(@contacts, meta: { custom: 'value' })
#   end
#
#   def create
#     error_response(ApiErrorCodes::VALIDATION_ERROR, 'Invalid email', status: :unprocessable_entity)
#   end
#
module ApiResponseHelper
  extend ActiveSupport::Concern

  # Returns a successful response with standard format
  #
  # @param data [Object, Array, Hash] The response data (resource or collection)
  # @param meta [Hash] Additional metadata (optional)
  # @param message [String] Optional success message
  # @param status [Symbol] HTTP status code (default: :ok)
  #
  # @example Single resource
  #   success_response(@contact)
  #   # => { success: true, data: {...}, meta: { timestamp: "..." } }
  #
  # @example Collection
  #   success_response(@contacts, meta: { total: 100 })
  #   # => { success: true, data: [...], meta: { total: 100, timestamp: "..." } }
  #
  # @example With message
  #   success_response(@contact, message: "Contact created successfully", status: :created)
  #
  def success_response(data: data, meta: {}, message: nil, status: :ok)
    response_body = {
      success: true,
      data: data
    }

    # Always include meta with timestamp
    response_body[:meta] = meta.merge(timestamp: Time.current.iso8601)

    # Optional message field
    response_body[:message] = message if message.present?

    render json: response_body, status: status
  end

  # Returns an error response with standard format
  #
  # @param code [String] Error code from ApiErrorCodes module
  # @param message [String] Human-readable error message
  # @param details [Array, Hash, String] Additional error details (optional)
  # @param status [Symbol] HTTP status code (default: :bad_request)
  #
  # @example Simple error
  #   error_response(ApiErrorCodes::VALIDATION_ERROR, "Email is required")
  #
  # @example With details
  #   error_response(
  #     ApiErrorCodes::VALIDATION_ERROR,
  #     "Validation failed",
  #     details: [{ field: "email", message: "is required" }],
  #     status: :unprocessable_entity
  #   )
  #
  def error_response(code, message, details: nil, status: :bad_request)
    # An exception raised after the action already rendered lands here through
    # rescue_from. Rendering again raises DoubleRenderError, which replaces the
    # real error with a generic 500 and hides it from the response AND the log.
    # The rendered response is already on its way, so the error can only be
    # logged.
    if performed?
      Rails.logger.error(
        "[api] #{code}: #{message} could not be rendered — response already sent " \
        "for #{request.method} #{request.path}"
      )
      return
    end

    response_body = {
      success: false,
      error: {
        code: code,
        message: message
      },
      meta: {
        timestamp: Time.current.iso8601,
        path: request.path,
        method: request.method
      }
    }

    # Add details if present
    response_body[:error][:details] = details if details.present?

    render json: response_body, status: status
  end

  # Returns a paginated response with complete pagination metadata
  #
  # @param data [Array, Hash] The paginated data (serialized)
  # @param collection [ActiveRecord::Relation] The original collection (for auto-pagination)
  # @param pagination_meta [Hash] Manual pagination metadata (optional if collection provided)
  #   @option pagination_meta [Integer] :page Current page number
  #   @option pagination_meta [Integer] :page_size Number of items per page
  #   @option pagination_meta [Integer] :total Total number of items
  #   @option pagination_meta [Integer] :total_pages Total number of pages
  #   @option pagination_meta [Boolean] :has_next_page Whether there's a next page
  #   @option pagination_meta [Boolean] :has_previous_page Whether there's a previous page
  # @param message [String] Optional message
  # @param status [Symbol] HTTP status code (default: :ok)
  #
  # @example With collection (auto-pagination)
  #   paginated_response(
  #     data: ContactSerializer.serialize_collection(@contacts),
  #     collection: @contacts,
  #     message: 'Contacts retrieved'
  #   )
  #
  # @example With manual pagination_meta
  #   paginated_response(
  #     data: serialized_data,
  #     pagination_meta: {
  #       page: 1,
  #       page_size: 20,
  #       total: 156,
  #       total_pages: 8,
  #       has_next_page: true,
  #       has_previous_page: false
  #     }
  #   )
  #
  def paginated_response(data: data, collection: nil, pagination_meta: nil, meta: {}, message: nil, status: :ok)
    # Auto-generate pagination metadata from collection if not provided
    if pagination_meta.nil? && !collection.nil?
      # Check if collection is paginated (has Kaminari methods)
      if defined?(Kaminari) && collection.respond_to?(:current_page) && collection.respond_to?(:total_count)
        begin
          page_size = collection.limit_value
          if page_size.nil? || page_size.zero?
            page_size = params[:pageSize]&.to_i || params[:page_size]&.to_i || params[:per_page]&.to_i || 20
          end
          page_size = [page_size.to_i, 1].max

          pagination_meta = {
            page: collection.current_page,
            page_size: page_size,
            total: collection.total_count,
            total_pages: collection.total_pages,
            has_next_page: collection.current_page < collection.total_pages,
            has_previous_page: collection.current_page > 1
          }
        rescue NoMethodError
          # Collection might not be fully paginated, fall back to manual calculation
          pagination_meta = nil
        end
      end

      # If collection is not paginated, build pagination meta manually
      if pagination_meta.nil?
        page = params[:page]&.to_i || 1
        page_size = params[:pageSize]&.to_i || params[:page_size]&.to_i || params[:per_page]&.to_i || 20
        page_size = [page_size.to_i, 1].max

        total = begin
          if collection.respond_to?(:count)
            collection.count
          elsif collection.is_a?(Array)
            collection.size
          elsif collection.respond_to?(:size)
            collection.size
          else
            collection.to_a.size
          end
        rescue => e
          Rails.logger.error "Error counting collection: #{e.message}"
          0
        end

        total_pages = (total.to_f / page_size).ceil
        total_pages = 1 if total_pages < 1

        pagination_meta = {
          page: page,
          page_size: page_size,
          total: total,
          total_pages: total_pages,
          has_next_page: page < total_pages,
          has_previous_page: page > 1
        }
      end
    end

    # If still no pagination_meta, raise error
    if pagination_meta.nil?
      raise ArgumentError, 'paginated_response requires either :collection or :pagination_meta parameter'
    end

    success_response(
      data: data,
      meta: meta.merge({
        pagination: {
          page: pagination_meta[:page] || pagination_meta[:current_page],
          page_size: pagination_meta[:page_size] || pagination_meta[:pageSize] || pagination_meta[:per_page] || pagination_meta[:limit_value],
          total: pagination_meta[:total] || pagination_meta[:total_count],
          total_pages: [pagination_meta[:total_pages] || pagination_meta[:totalPages] || 0, 1].max,
          has_next_page: pagination_meta.key?(:has_next_page) ? pagination_meta[:has_next_page] : pagination_meta[:hasNextPage],
          has_previous_page: pagination_meta.key?(:has_previous_page) ? pagination_meta[:has_previous_page] : pagination_meta[:hasPreviousPage]
        }
      }),
      message: message,
      status: status
    )
  end

  # Helper method to build pagination metadata from a collection
  #
  # @param collection [ActiveRecord::Relation, Array] The collection to paginate
  # @param page [Integer] Current page number (1-indexed)
  # @param page_size [Integer] Number of items per page
  # @param total_count [Integer] Total count (optional, will be calculated if not provided)
  #
  # @return [Hash] Pagination metadata hash ready for paginated_response
  #
  # @example
  #   pagination = build_pagination_meta(@contacts, page: params[:page], page_size: 20)
  #   paginated_response(@contacts, pagination_meta: pagination)
  #
  def build_pagination_meta(collection, page:, page_size:, total_count: nil)
    page = page.to_i
    page = 1 if page < 1
    page_size = page_size.to_i
    page_size = 15 if page_size < 1

    # Calculate total count
    total = total_count || (collection.respond_to?(:count) ? collection.count : collection.size)
    total_pages = (total.to_f / page_size).ceil
    total_pages = 1 if total_pages < 1

    {
      page: page,
      page_size: page_size,
      total: total,
      total_pages: total_pages,
      has_next_page: page < total_pages,
      has_previous_page: page > 1
    }
  end

  # Helper to serialize a single resource or collection
  #
  # @param resource [Object, Array] Resource or collection to serialize
  # @param options [Hash] Options for serialization (methods to include, associations, etc)
  #
  # @return [Hash, Array] Serialized data ready for Oj
  #
  # @example
  #   serialize(@contact, methods: [:avatar_url], include: [:labels])
  #   serialize(@contacts, only: [:id, :name, :email])
  #
  def serialize(resource, **options)
    if resource.is_a?(Array) || resource.is_a?(ActiveRecord::Relation)
      # Collection - Oj will handle the array serialization
      resource.map { |item| item.as_json(options) }
    elsif resource.respond_to?(:as_json)
      # Single resource - let Oj optimize the conversion
      resource.as_json(options)
    else
      # Fallback for plain hashes/arrays
      resource
    end
  end

  # Helper to extract pagination params from request
  #
  # @return [Hash] Normalized pagination parameters
  #   { page: Integer, page_size: Integer, sort_by: String, sort_order: String }
  #
  def pagination_params
    {
      page: params[:page]&.to_i || 1,
      page_size: params[:pageSize]&.to_i || params[:per_page]&.to_i || 15,
      sort_by: params[:sortBy] || params[:sort_by] || 'created_at',
      sort_order: params[:sortOrder] || params[:sort_order] || 'desc'
    }
  end

  # Helper to build compact JSON representation of a resource
  # Optimized for Oj - returns plain Hash without intermediate serializers
  #
  # @param resource [ActiveRecord::Base] The resource to serialize
  # @param options [Hash] Serialization options
  #   @option options [Array<Symbol>] :only Fields to include
  #   @option options [Array<Symbol>] :except Fields to exclude
  #   @option options [Array<Symbol>] :methods Additional methods to call
  #   @option options [Hash] :include Associations to include
  #
  # @return [Hash] Compact hash ready for Oj serialization
  #
  # @example
  #   compact_serialize(@contact, only: [:id, :name, :email], methods: [:avatar_url])
  #
  def compact_serialize(resource, **options)
    # Let Oj handle the conversion - as_json is optimized by Oj when configured
    resource.as_json(options)
  end

  # Helper to build compact JSON for collections
  # Uses Oj's optimized array handling
  #
  # @param collection [Array, ActiveRecord::Relation] Collection to serialize
  # @param options [Hash] Same as compact_serialize
  #
  # @return [Array<Hash>] Array of compact hashes
  #
  def compact_serialize_collection(collection, **options)
    collection.map { |item| compact_serialize(item, options) }
  end
end
