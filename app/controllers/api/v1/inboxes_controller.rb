# frozen_string_literal: true

module Api
  module V1
      class InboxesController < Api::V1::BaseController
        include Api::V1::InboxesHelper
        include Api::V1::ResourceLimitsHelper

        rescue_from Sendgrid::InvalidApiKeyError, with: :handle_sendgrid_invalid_key
        rescue_from Sendgrid::ServiceUnavailableError, with: :handle_sendgrid_unavailable

        before_action :fetch_inbox, except: %i[index create]
        before_action :fetch_agent_bot, only: [:set_agent_bot]
        before_action :validate_limit, only: [:create]
        before_action :validate_channel_limit_for_creation, only: [:create]
        # we are already handling the authorization in fetch inbox

        require_permissions({
          index: 'inboxes.read',
          show: 'inboxes.read',
          create: 'inboxes.create',
          update: 'inboxes.update',
          destroy: 'inboxes.delete',
          assignable_agents: 'inboxes.read',
          agent_bot: 'inboxes.read',
          set_agent_bot: 'inboxes.update',
          setup_channel_provider: 'inboxes.update',
          disconnect_channel_provider: 'inboxes.update',
          sync_whatsapp_subscription: 'inboxes.update',
          avatar: 'inboxes.update',
          # Template CRUD moved to MessageTemplatesController (EVO-1716); only the
          # per-channel Meta sync remains here, keeping its inbox permission.
          sync_message_templates: 'inboxes.message_templates',
          sync_template_with_whatsapp_cloud: 'inboxes.message_templates',
          facebook_posts: 'inboxes.read'
        })

        def index
          @inboxes = Inbox.order_by_name.includes(:channel, { avatar_attachment: [:blob] })

          apply_pagination

          paginated_response(
            data: InboxSerializer.serialize_collection(@inboxes),
            collection: @inboxes,
            message: 'Inboxes retrieved successfully'
          );
        end

        def show
          success_response(
            data: InboxSerializer.serialize(@inbox),
            message: 'Inbox retrieved successfully'
          )
        end

        # Deprecated: This API will be removed in 2.7.0
        def assignable_agents
          @assignable_agents = @inbox.assignable_agents
        end

        def avatar
          @inbox.avatar.attachment.destroy! if @inbox.avatar.attached?
          success_response(
            data: nil,
            message: 'Avatar removed successfully',
            status: :no_content
          )
        end

        def create
          # Evolution Hub short-circuits. Duas rotas:
          #   - via_hub_existing + hub_channel_id → linka inbox a canal Hub
          #     preexistente (só cria webhook no Hub e ativa direto)
          #   - via_hub → cria canal NOVO no Hub via InboxBuilder
          if params[:via_hub_existing] && MetaBaseUrl.enabled? &&
             EvolutionHub::ExistingChannelLinker::SUPPORTED_TYPES.key?(params[:inbox]&.dig(:channel_type).to_s)
            return link_existing_evolution_hub_channel
          end

          if params[:via_hub] && MetaBaseUrl.enabled? &&
             EvolutionHub::InboxBuilder::SUPPORTED_TYPES.key?(params[:inbox]&.dig(:channel_type).to_s)
            return create_via_evolution_hub
          end

          ActiveRecord::Base.transaction do
            channel = create_channel
            # Para Telegram, garantir que bot_name esteja disponível
            # O bot_name é definido no before_validation durante o create!
            # Após create!, o bot_name já está no objeto em memória e no banco
            if channel.is_a?(Channel::Telegram)
              # Recarregar para garantir que temos o bot_name do banco
              channel.reload
              Rails.logger.info "[InboxesController] Telegram channel created - bot_name: #{channel.bot_name.inspect}"
            end
            inbox_params = permitted_params.except(:channel, :display_name, :name)
            inbox_name_value = inbox_name(channel)
            # Para Telegram, usar o bot_name também como display_name se não foi fornecido
            if channel.is_a?(Channel::Telegram) && permitted_params[:display_name].blank? && params[:inbox]&.dig(:display_name).blank?
              inbox_params[:display_name] = inbox_name_value
            else
              inbox_params[:display_name] = permitted_params[:display_name] || params[:inbox]&.dig(:display_name)
            end
            @inbox = Inbox.new(
              {
                name: inbox_name_value,
                channel: channel
              }.merge(inbox_params)
            )
            Rails.logger.info "[InboxesController] Creating inbox with name: #{@inbox.name.inspect}, display_name: #{@inbox.display_name.inspect}"
            @inbox.save!
            # Recarregar o inbox para garantir que temos os valores finais do banco
            @inbox.reload
            Rails.logger.info "[InboxesController] Inbox saved - name: #{@inbox.name.inspect}, display_name: #{@inbox.display_name.inspect}"
          end

          success_response(
            data: InboxSerializer.serialize(@inbox),
            message: 'Inbox created successfully',
            status: :created
          )
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
          record = e.respond_to?(:record) ? e.record : nil
          error_response(
            ApiErrorCodes::VALIDATION_ERROR,
            record&.errors&.full_messages&.to_sentence.presence || e.message,
            details: record.present? ? format_validation_errors(record.errors) : nil,
            status: :unprocessable_entity
          )
        end

        def update
          inbox_params = permitted_params.except(:channel, :csat_config)
          if permitted_params[:csat_config].present?
            inbox_params[:csat_config] =
              format_csat_config(permitted_params[:csat_config])
          end
          @inbox.update!(inbox_params)
          update_inbox_working_hours
          update_channel if channel_update_required?

          success_response(
            data: InboxSerializer.serialize(@inbox),
            message: 'Inbox updated successfully'
          )
        end

        def agent_bot
          @agent_bot = @inbox.agent_bot
          @agent_bot_inbox = @inbox.agent_bot_inbox
          
          success_response(
            data: AgentBotSerializer.serialize(@agent_bot, agent_bot_inbox: @agent_bot_inbox),
            message: 'Agent bot retrieved successfully'
          )
        end

        def set_agent_bot
          if @agent_bot
            agent_bot_inbox = @inbox.agent_bot_inbox || AgentBotInbox.new(inbox: @inbox)
            agent_bot_inbox.agent_bot = @agent_bot

            # Update configuration fields if provided
            if params[:agent_bot_config].present?
              config_params = params[:agent_bot_config]

              # Handle conversation statuses - default to ['pending'] if empty
              if config_params.key?(:allowed_conversation_statuses)
                statuses = config_params[:allowed_conversation_statuses] || []
                agent_bot_inbox.allowed_conversation_statuses = statuses.empty? ? ['pending'] : statuses
              else
                # Default to pending if not provided
                agent_bot_inbox.allowed_conversation_statuses = ['pending']
              end

              # Handle label IDs
              if config_params.key?(:allowed_label_ids)
                agent_bot_inbox.allowed_label_ids = config_params[:allowed_label_ids] || []
              end

              # Handle ignored label IDs
              if config_params.key?(:ignored_label_ids)
                agent_bot_inbox.ignored_label_ids = config_params[:ignored_label_ids] || []
              end

              # Handle Facebook comment configuration
              if config_params.key?(:facebook_comment_replies_enabled)
                agent_bot_inbox.facebook_comment_replies_enabled = config_params[:facebook_comment_replies_enabled]
                Rails.logger.info "[InboxesController] Set facebook_comment_replies_enabled: #{agent_bot_inbox.facebook_comment_replies_enabled}"
              end

              if config_params.key?(:facebook_comment_agent_bot_id)
                old_value = agent_bot_inbox.facebook_comment_agent_bot_id
                new_value = config_params[:facebook_comment_agent_bot_id]
                # Handle null, empty string, or "same" value as nil
                agent_bot_inbox.facebook_comment_agent_bot_id = (new_value.present? && new_value != 'same') ? new_value : nil
                Rails.logger.info "[InboxesController] Set facebook_comment_agent_bot_id: #{old_value} -> #{agent_bot_inbox.facebook_comment_agent_bot_id} (raw: #{new_value.inspect})"
              end

              # Handle Facebook interaction type
              if config_params.key?(:facebook_interaction_type)
                agent_bot_inbox.facebook_interaction_type = config_params[:facebook_interaction_type] || 'both'
                Rails.logger.info "[InboxesController] Set facebook_interaction_type: #{agent_bot_inbox.facebook_interaction_type}"
              end

              # Handle Facebook allowed post IDs
              if config_params.key?(:facebook_allowed_post_ids)
                agent_bot_inbox.facebook_allowed_post_ids = config_params[:facebook_allowed_post_ids] || []
                Rails.logger.info "[InboxesController] Set facebook_allowed_post_ids: #{agent_bot_inbox.facebook_allowed_post_ids.inspect}"
              end

              # Handle moderation configuration
              if config_params.key?(:moderation_enabled)
                agent_bot_inbox.moderation_enabled = config_params[:moderation_enabled] || false
              end

              if config_params.key?(:explicit_words_filter)
                agent_bot_inbox.explicit_words_filter = config_params[:explicit_words_filter] || []
              end

              if config_params.key?(:sentiment_analysis_enabled)
                agent_bot_inbox.sentiment_analysis_enabled = config_params[:sentiment_analysis_enabled] || false
              end

              if config_params.key?(:auto_approve_responses)
                agent_bot_inbox.auto_approve_responses = config_params[:auto_approve_responses] || false
              end

              if config_params.key?(:auto_reject_explicit_words)
                agent_bot_inbox.auto_reject_explicit_words = config_params[:auto_reject_explicit_words] || false
                Rails.logger.info "[InboxesController] Set auto_reject_explicit_words: #{agent_bot_inbox.auto_reject_explicit_words} (raw: #{config_params[:auto_reject_explicit_words].inspect})"
              end

              if config_params.key?(:auto_reject_offensive_sentiment)
                agent_bot_inbox.auto_reject_offensive_sentiment = config_params[:auto_reject_offensive_sentiment] || false
                Rails.logger.info "[InboxesController] Set auto_reject_offensive_sentiment: #{agent_bot_inbox.auto_reject_offensive_sentiment} (raw: #{config_params[:auto_reject_offensive_sentiment].inspect})"
              end
            else
              # Default to pending if no config provided
              agent_bot_inbox.allowed_conversation_statuses = ['pending']
              agent_bot_inbox.allowed_label_ids = []
              agent_bot_inbox.ignored_label_ids = []
            end

            agent_bot_inbox.status = :active
            agent_bot_inbox.save!
          elsif @inbox.agent_bot_inbox.present?
            @inbox.agent_bot_inbox.destroy!
          end

          success_response(
            data: nil,
            message: 'Agent bot configured successfully'
          )
        end

        def facebook_posts
          unless @inbox.facebook?
            return error_response(
              ApiErrorCodes::INVALID_PARAMETER,
              'Inbox is not a Facebook page',
              status: :bad_request
            )
          end

          limit = params[:limit]&.to_i || 25
          limit = [limit, 100].min # Max 100 posts

          posts = Facebook::FetchPagePostsService.new(
            channel: @inbox.channel,
            limit: limit
          ).perform

          success_response(
            data: { posts: posts },
            message: 'Facebook posts retrieved successfully'
          )
        rescue StandardError => e
          Rails.logger.error("FacebookPostsController: Error fetching posts: #{e.message}")
          Rails.logger.error(e.backtrace.join("\n"))
          error_response(
            ApiErrorCodes::INTERNAL_ERROR,
            'Failed to fetch Facebook posts',
            details: e.message,
            status: :internal_server_error
          )
        end

        def setup_channel_provider
          channel = @inbox.channel

          unless channel.respond_to?(:setup_channel_provider)
            return error_response(
              ApiErrorCodes::OPERATION_NOT_ALLOWED,
              'Channel does not support setup',
              status: :unprocessable_entity
            )
          end

          channel.setup_channel_provider
          success_response(
            data: nil,
            message: 'Channel provider setup completed successfully'
          )
        end

        def disconnect_channel_provider
          channel = @inbox.channel

          unless channel.respond_to?(:disconnect_channel_provider)
            return error_response(
              ApiErrorCodes::OPERATION_NOT_ALLOWED,
              'Channel does not support disconnect',
              status: :unprocessable_entity
            )
          end

          channel.disconnect_channel_provider
          success_response(
            data: nil,
            message: 'Channel provider disconnected successfully'
          )
        ensure
          channel.update_provider_connection!(connection: 'close') if channel.respond_to?(:update_provider_connection!)
        end

        # Re-subscribe a WhatsApp Cloud channel to Meta's subscribed_apps endpoint
        # without going through a full OAuth reconnect. Useful when the credentials
        # are still valid but the webhook subscription was dropped (number shows as
        # disconnected even though api_key/waba_id are intact).
        def sync_whatsapp_subscription
          channel = @inbox.channel

          unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
            return error_response(
              ApiErrorCodes::OPERATION_NOT_ALLOWED,
              'Channel does not support webhook resubscription',
              status: :unprocessable_entity
            )
          end

          channel.subscribe
          success_response(
            data: nil,
            message: 'WhatsApp webhook subscription refreshed successfully'
          )
        end

        def sync_message_templates
          Rails.logger.info '=== SYNC MESSAGE TEMPLATES START ==='
          authorize @inbox, :message_templates?

          begin
            # For WhatsApp channels, use the existing sync_templates method
            if @inbox.channel.respond_to?(:sync_templates)
              @inbox.channel.sync_templates
              templates = @inbox.channel.message_templates.active

              success_response(
                data: templates.map(&:serialized),
                message: 'Templates synchronized successfully'
              )
            else
              # For other channels, just return the current templates
              templates = @inbox.channel.message_templates.active

              success_response(
                data: templates.map(&:serialized),
                message: 'Sync not supported for this channel type'
              )
            end
          rescue StandardError => e
            Rails.logger.error "Sync message templates error: #{e.message}"
            Rails.logger.error "Error backtrace: #{e.backtrace.first(10).join("\n")}"
            error_response(
              ApiErrorCodes::INTERNAL_ERROR,
              'Failed to sync message templates',
              details: e.message,
              status: :unprocessable_entity
            )
          ensure
            Rails.logger.info '=== SYNC MESSAGE TEMPLATES END ==='
          end
        end

        # Pushes a single template up to Meta (WhatsApp Cloud) for approval. The
        # inbox :id is a routing placeholder; the template's OWN channel supplies
        # the WABA, so the template must already be bound to a WhatsApp Cloud
        # channel. Async — enqueues the sync job and returns 202. (EVO-1232)
        # Authorization is enforced by the `require_permissions` before_action
        # (inboxes.message_templates). We deliberately do NOT call the in-action
        # `authorize @inbox, :message_templates?`: under service-token auth there is
        # no Pundit user, so it would raise. Mirrors EVO-1231's global path. (F7)
        def sync_template_with_whatsapp_cloud
          template = MessageTemplate.find(params[:template_id])
          channel = template.channel

          unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
            return error_response(
              ApiErrorCodes::VALIDATION_ERROR,
              'Template must reference a WhatsApp Cloud channel to sync',
              status: :unprocessable_entity
            )
          end

          SyncMessageTemplateWithWhatsappCloudJob.perform_later(template)
          success_response(
            data: { template: template.serialized },
            message: 'WhatsApp Cloud template sync enqueued',
            status: :accepted
          )
        rescue ActiveRecord::RecordNotFound
          error_response(ApiErrorCodes::RESOURCE_NOT_FOUND, 'Message template not found', status: :not_found)
        end

        def destroy
          ::DeleteObjectJob.perform_later(@inbox, Current.user, request.ip) if @inbox.present?
          success_response(
            data: { id: @inbox.id },
            message: I18n.t('messages.inbox_deletetion_response')
          )
        end

        private

        # Hub-relayed Inbox creation. Delegates to EvolutionHub::InboxBuilder
        # and renders the standard InboxSerializer plus the public_link the
        # frontend uses to open the Hub connect flow in a new tab.
        #
        # Accepts an optional `channel_credentials_id` in the inbox params,
        # which the Hub uses to bind the new channel to a specific BYO Meta
        # App registered by the user. Required for plans that don't allow
        # the shared Evolution Cloud Meta App (ex.: free tier).
        def create_via_evolution_hub
          result = EvolutionHub::InboxBuilder.new(
            channel_type: params[:inbox][:channel_type].to_s,
            name: params[:inbox][:name].to_s,
            channel_credentials_id: params[:inbox][:channel_credentials_id]
          ).perform

          @inbox = result[:inbox]

          success_response(
            data: InboxSerializer.serialize(@inbox).merge(
              evolution_hub: {
                public_link: result[:public_link]
              }
            ),
            message: 'Inbox created via Evolution Hub. Open the public link to finish connecting the Meta channel.',
            status: :created
          )
        rescue EvolutionHub::Client::ConfigurationError => e
          Rails.logger.error("EvolutionHub config error: #{e.message}")
          error_response(
            ApiErrorCodes::INVALID_PARAMETER,
            "Evolution Hub não está configurado neste workspace. Avise um administrador.",
            status: :bad_gateway
          )
        rescue EvolutionHub::Client::RequestError => e
          Rails.logger.error(
            "EvolutionHub inbox creation failed: HTTP #{e.status} code=#{e.code.inspect} body=#{e.body}"
          )
          error_response(
            ApiErrorCodes::INVALID_PARAMETER,
            evolution_hub_user_message(e),
            details: evolution_hub_error_details(e),
            status: hub_error_http_status(e)
          )
        end

        # Linka inbox a um canal Hub PREEXISTENTE. Não cria canal no Hub,
        # só um webhook associado. Canal local sobe direto como 'active'.
        def link_existing_evolution_hub_channel
          result = EvolutionHub::ExistingChannelLinker.new(
            channel_type: params[:inbox][:channel_type].to_s,
            name: params[:inbox][:name].to_s,
            hub_channel_id: params[:hub_channel_id].to_s
          ).perform

          @inbox = result[:inbox]

          success_response(
            data: InboxSerializer.serialize(@inbox).merge(
              evolution_hub: {
                linked: true,
                hub_channel_id: result[:hub_channel]['id']
              }
            ),
            message: 'Inbox vinculada a canal Evo Hub existente.',
            status: :created
          )
        rescue EvolutionHub::ExistingChannelLinker::AlreadyLinked => e
          error_response(ApiErrorCodes::INVALID_PARAMETER, e.message, status: :conflict)
        rescue EvolutionHub::ExistingChannelLinker::ChannelTypeMismatch,
               EvolutionHub::ExistingChannelLinker::UnsupportedChannelType => e
          error_response(ApiErrorCodes::INVALID_PARAMETER, e.message, status: :unprocessable_entity)
        rescue EvolutionHub::Client::ConfigurationError => e
          Rails.logger.error("EvolutionHub config error: #{e.message}")
          error_response(
            ApiErrorCodes::INVALID_PARAMETER,
            'Evolution Hub não está configurado neste workspace. Avise um administrador.',
            status: :bad_gateway
          )
        rescue EvolutionHub::Client::RequestError => e
          Rails.logger.error(
            "EvolutionHub link existing failed: HTTP #{e.status} code=#{e.code.inspect} body=#{e.body}"
          )
          error_response(
            ApiErrorCodes::INVALID_PARAMETER,
            evolution_hub_user_message(e),
            details: evolution_hub_error_details(e),
            status: hub_error_http_status(e)
          )
        end

        # Mapeia códigos de erro do Hub em mensagens úteis em pt-BR.
        # Lista alinhada com `frontend/client/src/lib/api-errors.ts` do Hub.
        def evolution_hub_user_message(err)
          case err.code
          when 'PLAN_FORBIDS_SHARED'
            'Seu plano no Evolution Hub exige cadastrar uma Meta App própria (BYO) ' \
              'antes de criar este canal. Configure em Evolution Hub → Meta Apps.'
          when 'PLAN_FORBIDS_BYO'
            'Seu plano no Evolution Hub não permite Meta App própria. Use a Meta App ' \
              'compartilhada da plataforma.'
          when 'PLAN_QUOTA_EXCEEDED', 'QUOTA_EXCEEDED'
            'Limite do seu plano no Evolution Hub atingido. Faça upgrade ou remova ' \
              'canais/webhooks existentes.'
          when 'APP_ID_CONFLICT'
            'Este App ID da Meta já está cadastrado por outra conta. Cada Meta App ' \
              'só pode pertencer a um tenant.'
          when 'VERIFY_TOKEN_CONFLICT'
            'O verify token desta Meta App colide com outro existente.'
          else
            "Evolution Hub error: #{err.message}"
          end
        end

        # Quando temos info estruturada, anexa no payload pra debug no front.
        def evolution_hub_error_details(err)
          return nil if err.code.blank?
          { evolution_hub: { code: err.code, variables: err.variables }.compact }
        end

        # 403 do Hub vira 403 aqui (forbidden por plano/quota é semanticamente
        # forbidden, não bad_gateway). 4xx/5xx que não conhecemos viram 502.
        def hub_error_http_status(err)
          case err.status
          when 403 then :forbidden
          when 404 then :not_found
          when 409 then :conflict
          when 400, 422 then :unprocessable_entity
          else :bad_gateway
          end
        end

        def fetch_inbox
          @inbox = Inbox.find(params[:id])
          # Use destroy? permission for destroy action, show? for others
          permission = action_name == 'destroy' ? :destroy? : :show?
          authorize @inbox, permission
        end

        def fetch_agent_bot
          @agent_bot = AgentBot.find(params[:agent_bot]) if params[:agent_bot]
        rescue ActiveRecord::RecordNotFound
          @agent_bot = nil
        end

        def handle_sendgrid_invalid_key(exception)
          error_response(
            ApiErrorCodes::VALIDATION_ERROR,
            exception.message.presence || 'SendGrid API key is invalid',
            status: :unprocessable_entity
          )
        end

        def handle_sendgrid_unavailable(exception)
          error_response(
            ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
            exception.message.presence || 'SendGrid is currently unavailable',
            status: :service_unavailable
          )
        end

        def create_channel
          return unless %w[web_widget api email line telegram whatsapp sms sendgrid].include?(permitted_params[:channel][:type])

          # Debug logs for Evolution Go channel creation
          if permitted_params[:channel][:type] == 'whatsapp' && permitted_params[:channel][:provider] == 'evolution_go'
            Rails.logger.info "Creating Evolution Go channel with params: #{permitted_params[:channel].inspect}"
          end

          account_channels_method.create!(permitted_params(channel_type_from_params::EDITABLE_ATTRS)[:channel].except(:type))
        end

        def update_inbox_working_hours
          return unless params[:working_hours]

          @inbox.update_working_hours(params.permit(working_hours: Inbox::OFFISABLE_ATTRS)[:working_hours])
        end

        def update_channel
          channel_attributes = get_channel_attributes(@inbox.channel_type)
          return if permitted_params(channel_attributes)[:channel].blank?

          validate_and_update_email_channel(channel_attributes) if @inbox.inbox_type == 'Email'

          reauthorize_and_update_channel(channel_attributes)
          update_channel_feature_flags
        end

        def channel_update_required?
          permitted_params(get_channel_attributes(@inbox.channel_type))[:channel].present?
        end

        def validate_and_update_email_channel(channel_attributes)
          validate_email_channel(channel_attributes)
        rescue StandardError => e
          error_response(
            ApiErrorCodes::VALIDATION_ERROR,
            e.message,
            status: :unprocessable_entity
          )
          return
        end

        def reauthorize_and_update_channel(channel_attributes)
          @inbox.channel.reauthorized! if @inbox.channel.respond_to?(:reauthorized!)
          @inbox.channel.update!(permitted_params(channel_attributes)[:channel])
        end

        def update_channel_feature_flags
          return unless @inbox.web_widget?
          return unless permitted_params(Channel::WebWidget::EDITABLE_ATTRS)[:channel].key? :selected_feature_flags

          @inbox.channel.selected_feature_flags = permitted_params(Channel::WebWidget::EDITABLE_ATTRS)[:channel][:selected_feature_flags]
          @inbox.channel.save!
        end

        def format_csat_config(config)
          survey_rules = config.dig('survey_rules') || {}
          triggers = survey_rules['triggers'] || survey_rules[:triggers]

          if triggers.present? && triggers.is_a?(Array)
            normalized_triggers = triggers.map do |trigger|
              trigger_hash = case trigger
                             when ActionController::Parameters
                               trigger.to_h.deep_stringify_keys
                             when Hash
                               trigger.deep_stringify_keys
                             else
                               trigger.to_h.deep_stringify_keys
                             end
              
              # Ensure arrays are preserved correctly
              result = trigger_hash.with_indifferent_access
              
              # Explicitly preserve array fields
              result['stage_ids'] = Array(result['stage_ids']) if result.key?('stage_ids')
              result['values'] = Array(result['values']) if result.key?('values')
              
              result
            end
            {
              display_type: config['display_type'] || config[:display_type] || 'emoji',
              message: config['message'] || config[:message] || '',
              survey_rules: {
                triggers: normalized_triggers
              }
            }
          elsif survey_rules['operator'].present? || survey_rules[:operator].present?
            operator = survey_rules['operator'] || survey_rules[:operator] || 'contains'
            values = survey_rules['values'] || survey_rules[:values] || []
            {
              display_type: config['display_type'] || config[:display_type] || 'emoji',
              message: config['message'] || config[:message] || '',
              survey_rules: {
                triggers: [
                  {
                    type: 'label',
                    operator: operator,
                    values: values
                  }
                ]
              }
            }
          else
            {
              display_type: config['display_type'] || config[:display_type] || 'emoji',
              message: config['message'] || config[:message] || '',
              survey_rules: {
                triggers: []
              }
            }
          end
        end

        def inbox_attributes
          [:name, :avatar, :display_name, :greeting_enabled, :greeting_message, :greeting_message_template_id,
           :enable_email_collect, :csat_survey_enabled,
           :enable_auto_assignment, :working_hours_enabled, :out_of_office_message, :out_of_office_message_template_id,
           :timezone, :allow_messages_after_resolved,
           :lock_to_single_conversation, :sender_name_type, :business_name, :default_conversation_status,
           { csat_config: [:display_type, :message, { survey_rules: [:operator, { values: [] }, { triggers: [:type, :operator, { values: [] }, { stage_ids: [] }, :pattern, :field, :days, :time, :minutes] }] }] }]
        end

        def permitted_params(channel_attributes = [])
          # We will remove this line after fixing https://linear.app/evolution/issue/CW-1567/null-value-passed-as-null-string-to-backend
          params.each { |k, v| params[k] = params[k] == 'null' ? nil : v }

          params.permit(
            *inbox_attributes,
            channel: [:type, *channel_attributes]
          )
        end

        def channel_type_from_params
          {
            'web_widget' => Channel::WebWidget,
            'api' => Channel::Api,
            'email' => Channel::Email,
            'line' => Channel::Line,
            'telegram' => Channel::Telegram,
            'whatsapp' => Channel::Whatsapp,
            'sms' => Channel::Sms,
            'sendgrid' => Channel::Sendgrid
          }[permitted_params[:channel][:type]]
        end

        def get_channel_attributes(channel_type)
          if channel_type.constantize.const_defined?(:EDITABLE_ATTRS)
            channel_type.constantize::EDITABLE_ATTRS.presence
          else
            []
          end
        end

        def component_params
          [
            :type,
            :format,
            :text,
            :url,
            { buttons: button_params },
            { example: example_params }
          ]
        end

        def button_params
          [
            :type,
            :text,
            :url,
            :phone_number,
            { example: [:body_text] }
          ]
        end

        def example_params
          [
            :header_handle,
            { header_text: [] },
            { body_text: [] }
          ]
        end

        def whatsapp_inbox?
          @inbox.channel_type == 'Channel::Whatsapp'
        end

        def render_whatsapp_inbox_error
          Rails.logger.error "Not a WhatsApp inbox: #{@inbox.channel_type}"
          error_response(
            ApiErrorCodes::INVALID_PARAMETER,
            'Inbox is not a WhatsApp inbox',
            status: :unprocessable_entity
          )
        end

        def render_template_not_supported_error
          Rails.logger.error "Templates not supported for inbox type: #{@inbox.channel_type}"
          error_response(
            ApiErrorCodes::OPERATION_NOT_ALLOWED,
            'Templates not supported for this inbox type',
            status: :unprocessable_entity
          )
        end

        def render_template_name_required_error
          Rails.logger.error 'Template name is blank'
          error_response(
            ApiErrorCodes::MISSING_REQUIRED_FIELD,
            'Template name is required',
            status: :unprocessable_entity
          )
        end

        def extract_template_params
          params.require(:template).permit(
            :name, :category, :language, :message_send_ttl_seconds,
            components: [
              :type, :format, :text, :url,
              {
                buttons: [:type, :text, :url, :phone_number],
                example: {
                  header_text: [],
                  header_handle: [],
                  body_text: [[]]
                }
              }
            ]
          )
        end

      end
  end
end

Api::V1::InboxesController.prepend_mod_with('Api::V1::InboxesController')
