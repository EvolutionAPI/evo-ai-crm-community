module AgentBots
  class SessionSyncService
    def initialize(conversation)
      @conversation = conversation
      @inbox = conversation.inbox
      @agent_bot = @inbox&.agent_bot
    end

    def self.create_session_for_conversation(conversation)
      new(conversation).create_session
    end

    def self.delete_session_for_conversation(conversation)
      new(conversation).delete_session
    end

    def self.add_event_for_message(message)
      new(message.conversation).add_message_event(message)
    end

    def create_session
      return unless should_sync?

      agent_id = extract_agent_id
      return false unless agent_id

      session_id = build_session_id
      contact_id = @conversation.contact_id.to_s

      Rails.logger.info "[SessionSync] Creating session #{session_id} for conversation #{@conversation.id}"

      # Build metadata with contact data
      metadata = build_session_metadata

      begin
        response = make_request(
          :post,
          "/api/v1/sessions/sync/#{agent_id}",
          {
            session_id: session_id,
            user_id: contact_id,
            metadata: metadata
          }
        )

        if response&.code == '201' || response&.code == '200'
          Rails.logger.info "[SessionSync] ✅ Session #{session_id} created successfully"
          true
        else
          Rails.logger.error "[SessionSync] ❌ Failed to create session: #{response&.code} #{response&.body}"
          false
        end
      rescue StandardError => e
        Rails.logger.error "[SessionSync] ❌ Error creating session: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        false
      end
    end

    def delete_session
      return unless should_sync?

      agent_id = extract_agent_id
      return false unless agent_id

      session_id = build_session_id

      Rails.logger.info "[SessionSync] Deleting session #{session_id} for conversation #{@conversation.id}"
      Rails.logger.info "[SessionSync] Agent bot ID: #{@agent_bot&.id}, API key present: #{@agent_bot&.api_key.present?}"

      begin
        headers = build_headers
        Rails.logger.debug "[SessionSync] Request headers: #{headers.except('X-API-Key').merge('X-API-Key' => '[REDACTED]')}"

        response = make_request(
          :delete,
          "/api/v1/sessions/sync/#{session_id}",
          nil,
          headers: headers
        )

        if response&.code == '204' || response&.code == '200'
          Rails.logger.info "[SessionSync] ✅ Session #{session_id} deleted successfully"
          true
        else
          Rails.logger.error "[SessionSync] ❌ Failed to delete session: #{response&.code} #{response&.body}"
          false
        end
      rescue StandardError => e
        Rails.logger.error "[SessionSync] ❌ Error deleting session: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        false
      end
    end

    def add_message_event(message)
      return unless should_sync?

      agent_id = extract_agent_id
      return false unless agent_id

      session_id = build_session_id

      # Determine author and role based on message type
      author = message.incoming? ? 'user' : 'assistant'
      role = message.incoming? ? 'user' : 'model'

      # Extract message content
      content = extract_message_content(message)

      Rails.logger.info "[SessionSync] Adding event to session #{session_id} for message #{message.id}"

      # Get contact_id for user_id
      contact_id = @conversation.contact_id.to_s

      begin
        response = make_request(
          :post,
          "/api/v1/sessions/#{session_id}/events",
          {
            author: author,
            content: content,
            role: role,
            timestamp: message.created_at.to_f,
            user_id: contact_id
          }
        )

        if response&.code == '201' || response&.code == '200'
          Rails.logger.info "[SessionSync] ✅ Event added to session #{session_id} successfully"
          true
        else
          Rails.logger.error "[SessionSync] ❌ Failed to add event: #{response&.code} #{response&.body}"
          false
        end
      rescue StandardError => e
        Rails.logger.error "[SessionSync] ❌ Error adding event: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        false
      end
    end

    private

    def should_sync?
      return false unless @inbox&.active_bot?
      return false unless @agent_bot
      return false unless extract_agent_id.present?
      return false unless @conversation.contact_id.present?

      true
    end

    def extract_agent_id
      # Try to get agent_id from bot_config first (for future compatibility)
      if @agent_bot.bot_config.is_a?(Hash) && @agent_bot.bot_config['agent_id'].present?
        return @agent_bot.bot_config['agent_id'].to_s
      end

      # Extract agent_id from outgoing_url
      # Format: http://host/api/v1/a2a/{agent_id}
      outgoing_url = @agent_bot.outgoing_url
      return nil unless outgoing_url.present?

      # Match pattern: /api/v1/a2a/{agent_id}
      match = outgoing_url.match(%r{/api/v1/a2a/([^/?]+)})
      return match[1] if match

      # Fallback: try to extract from end of URL path
      uri = URI.parse(outgoing_url) rescue nil
      return nil unless uri

      path_segments = uri.path.split('/').reject(&:empty?)
      # Find the index of 'a2a' and get the next segment
      a2a_index = path_segments.index('a2a')
      return path_segments[a2a_index + 1] if a2a_index && path_segments[a2a_index + 1]

      nil
    end

    def build_session_id
      # Session ID format: {conversation.uuid}_{agent_id}
      # Uses the agent_id from outgoing_url (evo-core-service agent ID)
      # This matches the format used in a2a_routes.py: f"{external_id}_{agent_id}"
      agent_id = extract_agent_id
      return nil unless agent_id
      "#{@conversation.id}_#{agent_id}"
    end

    def extract_message_content(message)
      # Extract text content from message
      content = message.content

      # If content is HTML, try to extract plain text
      if content&.include?('<')
        # Simple HTML tag removal (can be improved)
        content = content.gsub(/<[^>]*>/, '')
      end

      content || ''
    end

    def make_request(method, endpoint, body = nil, headers: nil)
      base_url = ENV.fetch('EVO_AI_PROCESSOR_URL', 'http://localhost:8000')
      url = "#{base_url}#{endpoint}"

      request_headers = headers || build_headers

      Rails.logger.debug "[SessionSync] Making #{method.to_s.upcase} request to #{url}"

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 30
      http.open_timeout = 10

      request = case method
                when :get
                  Net::HTTP::Get.new(uri.path, request_headers)
                when :post
                  Net::HTTP::Post.new(uri.path, request_headers)
                when :delete
                  Net::HTTP::Delete.new(uri.path, request_headers)
                else
                  raise ArgumentError, "Unsupported HTTP method: #{method}"
                end

      request.body = body.to_json if body

      Rails.logger.debug "[SessionSync] Request body: #{body.to_json}" if body

      response = http.request(request)

      Rails.logger.debug "[SessionSync] Response: #{response.code} #{response.message}"
      Rails.logger.debug "[SessionSync] Response body: #{response.body}" if response.body.present?

      response
    end

    def build_session_metadata
      contact = @conversation.contact
      return nil unless contact

      {
        evoai_crm_event: 'conversation.created',
        evoai_crm_data: {
          conversation_id: @conversation.id.to_s,
          conversation_display_id: @conversation.display_id,
          inbox_id: @inbox.id.to_s
        },
        agent_bot_id: @agent_bot.id.to_s,
        agent_bot_name: @agent_bot.name,
        contactId: contact.id.to_s,
        contactName: contact.name,
        inboxId: @inbox.id.to_s,
        contact: build_contact_data(contact)
      }
    end

    def build_contact_data(contact)
      {
        id: contact.id.to_s,
        name: contact.name,
        email: contact.email,
        phone_number: contact.phone_number,
        identifier: contact.identifier,
        type: contact.type,
        contact_type: contact.contact_type,
        blocked: contact.blocked,
        location: contact.location,
        country_code: contact.country_code,
        industry: contact.industry,
        website: contact.website,
        tax_id: contact.tax_id,
        last_activity_at: contact.last_activity_at&.iso8601,
        created_at: contact.created_at&.iso8601,
        updated_at: contact.updated_at&.iso8601,
        additional_attributes: contact.additional_attributes || {},
        custom_attributes: contact.custom_attributes || {},
        labels: contact.labels.pluck(:name),
        companies: contact.companies.map { |c| { id: c.id.to_s, name: c.name } },
        pipelines: build_pipeline_data(contact)
      }
    end

    def build_pipeline_data(contact)
      contact.pipeline_items.includes(:pipeline, :pipeline_stage, :tasks).map do |item|
        {
          id: item.id.to_s,
          pipeline_id: item.pipeline_id.to_s,
          pipeline_name: item.pipeline&.name,
          stage_id: item.pipeline_stage_id.to_s,
          stage_name: item.pipeline_stage&.name,
          stage_position: item.pipeline_stage&.position,
          status: item.completed? ? 'completed' : 'pending',
          entered_at: item.entered_at&.iso8601,
          completed_at: item.completed_at&.iso8601,
          custom_fields: item.custom_fields || {},
          tasks: item.tasks.map { |task| { id: task.id.to_s, title: task.title, status: task.status } }
        }
      end
    end

    def build_headers
      {
        'Content-Type' => 'application/json',
        'Accept' => 'application/json',
        'X-API-Key' => AgentBots::CredentialResolution.api_key_for(@agent_bot)
      }
    end
  end
end

