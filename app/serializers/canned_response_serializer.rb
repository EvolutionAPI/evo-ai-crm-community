# frozen_string_literal: true

# CannedResponseSerializer - Optimized serialization for CannedResponse resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   CannedResponseSerializer.serialize(@canned_response)
#
module CannedResponseSerializer
  extend self

  # Serialize single CannedResponse
  #
  # @param canned_response [CannedResponse] CannedResponse to serialize
  # @param options [Hash] Serialization options
  #
  # @return [Hash] Serialized canned response ready for Oj
  #
  def serialize(canned_response)
    {
      id: canned_response.id,
      short_code: canned_response.short_code,
      content: canned_response.content,
      attachments: canned_response.attachments.map(&:push_event_data).compact,
      created_at: canned_response.created_at&.iso8601,
      updated_at: canned_response.updated_at&.iso8601
    }
  end

  # Serialize collection of CannedResponses
  #
  # @param canned_responses [Array<CannedResponse>, ActiveRecord::Relation]
  #
  # @return [Array<Hash>] Array of serialized canned responses
  #
  def serialize_collection(canned_responses)
    return [] unless canned_responses
    
    canned_responses.map { |response| serialize(response) }
  end
end
