# frozen_string_literal: true

# ApiErrorCodes - Standardized API Error Codes
#
# This module defines all error codes used across the API following the
# official API standard defined in API_RESPONSE_STANDARD.md
#
# Usage:
#   error_response(ApiErrorCodes::VALIDATION_ERROR, "Invalid email format")
#   error_response(ApiErrorCodes::CONTACT_NOT_FOUND, "Contact not found")
#
# Error codes follow the pattern: {DOMAIN}_{ERROR_TYPE}
# Examples: VALIDATION_ERROR, CONTACT_NOT_FOUND, UNAUTHORIZED
#
module ApiErrorCodes
  # ============================================================================
  # 400 Bad Request - Client errors (invalid input, validation failures)
  # ============================================================================
  
  VALIDATION_ERROR = 'VALIDATION_ERROR'
  INVALID_INPUT = 'INVALID_INPUT'
  MISSING_REQUIRED_FIELD = 'MISSING_REQUIRED_FIELD'
  INVALID_FORMAT = 'INVALID_FORMAT'
  INVALID_PARAMETER = 'INVALID_PARAMETER'
  INVALID_QUERY = 'INVALID_QUERY'
  MALFORMED_REQUEST = 'MALFORMED_REQUEST'

  # ============================================================================
  # 401 Unauthorized - Authentication failures
  # ============================================================================
  
  UNAUTHORIZED = 'UNAUTHORIZED'
  INVALID_TOKEN = 'INVALID_TOKEN'
  TOKEN_EXPIRED = 'TOKEN_EXPIRED'
  MISSING_TOKEN = 'MISSING_TOKEN'
  INVALID_CREDENTIALS = 'INVALID_CREDENTIALS'
  SESSION_EXPIRED = 'SESSION_EXPIRED'
  INVALID_SIGNATURE = 'INVALID_SIGNATURE'

  # ============================================================================
  # 403 Forbidden - Authorization failures (authenticated but not allowed)
  # ============================================================================
  
  FORBIDDEN = 'FORBIDDEN'
  INSUFFICIENT_PERMISSIONS = 'INSUFFICIENT_PERMISSIONS'
  ACCESS_DENIED = 'ACCESS_DENIED'
  ACCOUNT_SUSPENDED = 'ACCOUNT_SUSPENDED'
  ACCOUNT_LOCKED = 'ACCOUNT_LOCKED'
  FEATURE_NOT_AVAILABLE = 'FEATURE_NOT_AVAILABLE'

  # ============================================================================
  # 404 Not Found - Resource not found errors (specific resources)
  # ============================================================================
  
  RESOURCE_NOT_FOUND = 'RESOURCE_NOT_FOUND'
  UNKNOWN_PROVIDER = 'UNKNOWN_PROVIDER'

  # ============================================================================
  # 409 Conflict - Resource already exists or state conflicts
  # ============================================================================
  
  RESOURCE_ALREADY_EXISTS = 'RESOURCE_ALREADY_EXISTS'
  DUPLICATE_EMAIL = 'DUPLICATE_EMAIL'
  DUPLICATE_PHONE = 'DUPLICATE_PHONE'
  DUPLICATE_IDENTIFIER = 'DUPLICATE_IDENTIFIER'
  CONFLICT = 'CONFLICT'
  RESOURCE_IN_USE = 'RESOURCE_IN_USE'
  CANNOT_DELETE_ACTIVE_RESOURCE = 'CANNOT_DELETE_ACTIVE_RESOURCE'

  # ============================================================================
  # 422 Unprocessable Entity - Business logic violations
  # ============================================================================
  
  BUSINESS_RULE_VIOLATION = 'BUSINESS_RULE_VIOLATION'
  INVALID_STATE_TRANSITION = 'INVALID_STATE_TRANSITION'
  OPERATION_NOT_ALLOWED = 'OPERATION_NOT_ALLOWED'
  LIMIT_EXCEEDED = 'LIMIT_EXCEEDED'
  QUOTA_EXCEEDED = 'QUOTA_EXCEEDED'
  INVALID_OPERATION = 'INVALID_OPERATION'
  
  MAPPING_ERROR = 'MAPPING_ERROR'

  # Specific business rules
  CANNOT_DELETE_PIPELINE_WITH_CONVERSATIONS = 'CANNOT_DELETE_PIPELINE_WITH_CONVERSATIONS'
  CANNOT_MERGE_SAME_CONTACT = 'CANNOT_MERGE_SAME_CONTACT'
  CANNOT_TRANSFER_TO_SAME_INBOX = 'CANNOT_TRANSFER_TO_SAME_INBOX'
  INBOX_AGENT_LIMIT_REACHED = 'INBOX_AGENT_LIMIT_REACHED'

  # Template bundles (export/import)
  TEMPLATE_INVALID_BUNDLE = 'TEMPLATE_INVALID_BUNDLE'
  TEMPLATE_UNSUPPORTED_SCHEMA = 'TEMPLATE_UNSUPPORTED_SCHEMA'
  TEMPLATE_FILE_TOO_LARGE = 'TEMPLATE_FILE_TOO_LARGE'
  TEMPLATE_IMPORT_FAILED = 'TEMPLATE_IMPORT_FAILED'
  TEMPLATE_EXPORT_FAILED = 'TEMPLATE_EXPORT_FAILED'

  # ============================================================================
  # 429 Too Many Requests - Rate limiting
  # ============================================================================
  
  RATE_LIMIT_EXCEEDED = 'RATE_LIMIT_EXCEEDED'
  TOO_MANY_REQUESTS = 'TOO_MANY_REQUESTS'

  # ============================================================================
  # 500 Internal Server Error - Server errors
  # ============================================================================
  
  INTERNAL_ERROR = 'INTERNAL_ERROR'
  DATABASE_ERROR = 'DATABASE_ERROR'
  EXTERNAL_SERVICE_ERROR = 'EXTERNAL_SERVICE_ERROR'
  TIMEOUT_ERROR = 'TIMEOUT_ERROR'
  CONFIGURATION_ERROR = 'CONFIGURATION_ERROR'
  
  # External service specific
  WHATSAPP_API_ERROR = 'WHATSAPP_API_ERROR'
  FACEBOOK_API_ERROR = 'FACEBOOK_API_ERROR'
  INSTAGRAM_API_ERROR = 'INSTAGRAM_API_ERROR'
  GOOGLE_API_ERROR = 'GOOGLE_API_ERROR'
  MICROSOFT_API_ERROR = 'MICROSOFT_API_ERROR'
  AI_SERVICE_ERROR = 'AI_SERVICE_ERROR'
  
  # ============================================================================
  # 503 Service Unavailable - Service temporarily unavailable
  # ============================================================================
  
  SERVICE_UNAVAILABLE = 'SERVICE_UNAVAILABLE'
  MAINTENANCE_MODE = 'MAINTENANCE_MODE'
  DATABASE_UNAVAILABLE = 'DATABASE_UNAVAILABLE'

  # ============================================================================
  # Helper Methods
  # ============================================================================

  # Get HTTP status code for a given error code
  # @param error_code [String] Error code constant
  # @return [Symbol] HTTP status symbol
  def self.status_for(error_code)
    case error_code
    # 400 Bad Request
    when VALIDATION_ERROR, INVALID_INPUT, MISSING_REQUIRED_FIELD, INVALID_FORMAT,
         INVALID_PARAMETER, INVALID_QUERY, MALFORMED_REQUEST
      :bad_request
    
    # 401 Unauthorized
    when UNAUTHORIZED, INVALID_TOKEN, TOKEN_EXPIRED, MISSING_TOKEN,
         INVALID_CREDENTIALS, SESSION_EXPIRED, INVALID_SIGNATURE
      :unauthorized
    
    # 403 Forbidden
    when FORBIDDEN, INSUFFICIENT_PERMISSIONS, ACCESS_DENIED, ACCOUNT_SUSPENDED,
         ACCOUNT_LOCKED, FEATURE_NOT_AVAILABLE
      :forbidden
    
    # 404 Not Found
    when RESOURCE_NOT_FOUND, CONTACT_NOT_FOUND, CONVERSATION_NOT_FOUND, INBOX_NOT_FOUND,
         MESSAGE_NOT_FOUND, USER_NOT_FOUND, TEAM_NOT_FOUND, LABEL_NOT_FOUND,
         WEBHOOK_NOT_FOUND, INTEGRATION_NOT_FOUND, AGENT_BOT_NOT_FOUND,
         AUTOMATION_RULE_NOT_FOUND, MACRO_NOT_FOUND, PIPELINE_NOT_FOUND,
         PORTAL_NOT_FOUND, ARTICLE_NOT_FOUND, CATEGORY_NOT_FOUND,
         CANNED_RESPONSE_NOT_FOUND, CUSTOM_FILTER_NOT_FOUND, NOTIFICATION_NOT_FOUND,
         DASHBOARD_APP_NOT_FOUND, ACCOUNT_NOT_FOUND, CHANNEL_NOT_FOUND,
         AGENT_NOT_FOUND, CUSTOM_ATTRIBUTE_NOT_FOUND, COMPANY_NOT_FOUND,
         CONTACT_INBOX_NOT_FOUND, AI_AGENT_NOT_FOUND, AI_CUSTOM_TOOL_NOT_FOUND,
         MCP_SERVER_NOT_FOUND, PIPELINE_STAGE_NOT_FOUND, PIPELINE_ITEM_NOT_FOUND,
         PIPELINE_TASK_NOT_FOUND, UNKNOWN_PROVIDER
      :not_found
    
    # 409 Conflict
    when RESOURCE_ALREADY_EXISTS, DUPLICATE_EMAIL, DUPLICATE_PHONE,
         DUPLICATE_IDENTIFIER, CONFLICT, RESOURCE_IN_USE, CANNOT_DELETE_ACTIVE_RESOURCE
      :conflict
    
    # 422 Unprocessable Entity
    when BUSINESS_RULE_VIOLATION, INVALID_STATE_TRANSITION, OPERATION_NOT_ALLOWED,
         LIMIT_EXCEEDED, QUOTA_EXCEEDED, INVALID_OPERATION,
         CANNOT_DELETE_PIPELINE_WITH_CONVERSATIONS, CANNOT_MERGE_SAME_CONTACT,
         CANNOT_TRANSFER_TO_SAME_INBOX, INBOX_AGENT_LIMIT_REACHED,
         TEMPLATE_INVALID_BUNDLE, TEMPLATE_UNSUPPORTED_SCHEMA,
         TEMPLATE_IMPORT_FAILED, TEMPLATE_EXPORT_FAILED, MAPPING_ERROR
      :unprocessable_entity

    # 413 Payload Too Large
    when TEMPLATE_FILE_TOO_LARGE
      :payload_too_large

    # 429 Too Many Requests
    when RATE_LIMIT_EXCEEDED, TOO_MANY_REQUESTS
      :too_many_requests
    
    # 503 Service Unavailable
    when SERVICE_UNAVAILABLE, MAINTENANCE_MODE, DATABASE_UNAVAILABLE
      :service_unavailable
    
    # 500 Internal Server Error (default for unknown codes)
    else
      :internal_server_error
    end
  end

  # Check if error code is client error (4xx)
  # @param error_code [String] Error code constant
  # @return [Boolean]
  def self.client_error?(error_code)
    status = status_for(error_code)
    status.to_s.start_with?('4')
  end

  # Check if error code is server error (5xx)
  # @param error_code [String] Error code constant
  # @return [Boolean]
  def self.server_error?(error_code)
    status = status_for(error_code)
    status.to_s.start_with?('5')
  end
end
