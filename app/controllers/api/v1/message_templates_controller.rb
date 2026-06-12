# frozen_string_literal: true

module Api
  module V1
    # Dedicated, account-scoped CRUD for message templates. (EVO-1716)
    #
    # Replaces the inbox-nested member actions + `?global=true` toggle that used
    # to live in InboxesController. Serves BOTH:
    #   * global templates (channel-less) — the default when no inbox is given;
    #   * channel-bound templates — when `inbox_id` is present, the operation is
    #     delegated to that inbox's channel, preserving the WhatsApp Cloud
    #     writeback (create_template → Meta) exactly as before.
    #
    # Template sync with Meta stays inbox-scoped on InboxesController
    # (sync_message_templates / sync_template_with_whatsapp_cloud) — by nature
    # per-channel — and is intentionally NOT moved here.
    #
    # Templates are an instance-wide catalog (no account_id; this CRM runs against
    # a single runtime account). Authorization is by the `message_templates.*`
    # RBAC resource (via require_permissions) plus MessageTemplatePolicy.
    class MessageTemplatesController < Api::V1::BaseController
      include MessageTemplateParams

      require_permissions({
                            index: 'message_templates.read',
                            show: 'message_templates.read',
                            create: 'message_templates.create',
                            update: 'message_templates.update',
                            destroy: 'message_templates.delete'
                          })

      # GET /api/v1/message_templates
      # Filters: inbox_id (resolve inbox→channel) or neither (global catalog).
      # Plus category / template_type / search / sort_by / page / per_page.
      def index
        authorize MessageTemplate, :index?, policy_class: MessageTemplatePolicy

        @templates = filtered_templates

        return render_unpaginated if unpaginated?

        apply_pagination

        paginated_response(
          data: @templates.map(&:serialized),
          collection: @templates,
          message: 'Message templates retrieved successfully'
        )
      rescue ActiveRecord::RecordNotFound
        render_inbox_not_found
      rescue StandardError => e
        Rails.logger.error "Message templates list error: #{e.message}"
        error_response(ApiErrorCodes::INTERNAL_ERROR, e.message, status: :unprocessable_entity)
      end

      # GET /api/v1/message_templates/:id
      def show
        template = MessageTemplate.find(params[:id])
        authorize template, :show?, policy_class: MessageTemplatePolicy

        success_response(data: template.serialized, message: 'Message template retrieved successfully')
      rescue ActiveRecord::RecordNotFound
        error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Template not found', status: :not_found)
      end

      # POST /api/v1/message_templates
      def create
        authorize MessageTemplate, :create?, policy_class: MessageTemplatePolicy

        template = build_template(extract_message_template_params)
        success_response(data: template.serialized, message: 'Message template created successfully', status: :created)
      rescue ActiveRecord::RecordNotFound
        render_inbox_not_found
      rescue ActiveRecord::RecordInvalid => e
        error_response(ApiErrorCodes::VALIDATION_ERROR, e.message,
                       details: format_validation_errors(e.record.errors), status: :unprocessable_entity)
      rescue ActiveRecord::RecordNotUnique => e
        render_name_conflict(e)
      rescue StandardError => e
        Rails.logger.error "Message template creation error: #{e.message}"
        error_response(ApiErrorCodes::INTERNAL_ERROR, 'Failed to create message template',
                       details: e.message, status: :unprocessable_entity)
      end

      # PUT/PATCH /api/v1/message_templates/:id
      def update
        template = persist_update(extract_message_template_params)
        success_response(data: { template: template.serialized }, message: 'Template updated successfully')
      rescue ActiveRecord::RecordNotFound
        error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Template not found', status: :not_found)
      rescue ActiveRecord::RecordInvalid => e
        error_response(ApiErrorCodes::VALIDATION_ERROR, e.message,
                       details: format_validation_errors(e.record.errors), status: :unprocessable_entity)
      rescue ActiveRecord::RecordNotUnique => e
        render_name_conflict(e)
      rescue StandardError => e
        Rails.logger.error "Error in update message template: #{e.message}"
        error_response(ApiErrorCodes::INTERNAL_ERROR, 'Failed to update message template',
                       details: e.message, status: :unprocessable_entity)
      end

      # DELETE /api/v1/message_templates/:id
      def destroy
        if channel_bound?
          channel = resolve_channel
          authorize_template(:destroy?)
          channel.delete_message_template(params[:id])
        else
          template = global_scope.find(params[:id])
          authorize template, :destroy?, policy_class: MessageTemplatePolicy
          template.destroy!
        end

        success_response(data: nil, message: 'Template deleted successfully')
      rescue ActiveRecord::RecordNotFound
        error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Template not found', status: :not_found)
      rescue ActiveRecord::RecordNotDestroyed
        error_response(ApiErrorCodes::VALIDATION_ERROR, 'Template could not be deleted', status: :unprocessable_entity)
      rescue StandardError => e
        Rails.logger.error "Error in delete message template: #{e.message}"
        error_response(ApiErrorCodes::INTERNAL_ERROR, 'Failed to delete message template',
                       details: e.message, status: :unprocessable_entity)
      end

      private

      def unpaginated?
        params[:page]&.to_i == -1 || params[:per_page]&.to_i == -1
      end

      def render_unpaginated
        success_response(
          data: @templates.map(&:serialized),
          meta: { total: @templates.count, page: 1, per_page: @templates.count, total_pages: 1 },
          message: 'Message templates retrieved successfully'
        )
      end

      # Create dispatch: channel-bound (delegate to the channel, preserving the
      # provider's upstream writeback) vs global (channel-less local record).
      def build_template(template_params)
        return create_global_template(template_params) unless channel_bound?

        channel = resolve_channel
        if channel.respond_to?(:create_template)
          channel.create_template(template_params.to_h.stringify_keys)
        else
          channel.create_message_template(template_params)
        end
      end

      def create_global_template(template_params)
        # A self-reported provider == whatsapp_cloud is rejected by the model,
        # since a WhatsApp Cloud template must be bound to its channel.
        MessageTemplate.create!(
          template_params.to_h.merge(channel: nil, intended_provider: params.dig(:message_template, :provider))
        )
      end

      # Update dispatch mirrors create: channel-bound delegates to the channel;
      # global scopes to channel_id: nil so it cannot reach channel-bound rows.
      def persist_update(template_params)
        if channel_bound?
          channel = resolve_channel
          authorize_template(:update?)
          channel.update_message_template(params[:id], template_params)
        else
          template = global_scope.find(params[:id])
          authorize template, :update?, policy_class: MessageTemplatePolicy
          template.intended_provider = params.dig(:message_template, :provider)
          template.update!(template_params)
          template
        end
      end

      def filtered_templates
        scope = base_scope.active
        scope = scope.by_category(params[:category]) if params[:category].present?
        scope = scope.by_type(params[:template_type]) if params[:template_type].present?
        scope = scope.search_by_name(params[:search]) if params[:search].present?
        params[:sort_by] == 'name' ? scope.order(:name) : scope.recently_created
      end

      def base_scope
        return global_scope if params[:inbox_id].blank?

        channel = Inbox.find(params[:inbox_id]).channel
        channel ? channel.message_templates : MessageTemplate.none
      end

      def global_scope
        MessageTemplate.where(channel_id: nil)
      end

      # Channel-bound when an inbox is supplied; otherwise the operation targets
      # the global (channel-less) catalog.
      def channel_bound?
        params[:inbox_id].present?
      end

      def resolve_channel
        Inbox.find(params[:inbox_id]).channel
      end

      def authorize_template(action)
        authorize MessageTemplate.find(params[:id]), action, policy_class: MessageTemplatePolicy
      end

      def render_name_conflict(error)
        # Partial unique index race for global template names.
        Rails.logger.error "Template uniqueness conflict: #{error.message}"
        error_response(ApiErrorCodes::VALIDATION_ERROR, 'A template with this name already exists',
                       status: :unprocessable_entity)
      end

      def render_inbox_not_found
        error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Inbox not found', status: :not_found)
      end
    end
  end
end
