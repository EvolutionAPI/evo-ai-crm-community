Rails.application.routes.draw do
  get '/health/live', to: 'health#live'
  get '/health/ready', to: 'health#ready'
  get '/metrics', to: 'health#metrics'
  post '/api/v1/dynamic_oauth/validate_client', to: 'api/v1/dynamic_oauth#validate_dynamic_client'

  ## Renders the frontend paths only if this is not an API-only server.
  ## Default true: this backend is API-only (vite_rails removed); the SPA is served
  ## by the separate evo-frontend service. With default false the backend registered
  ## root->dashboard#index and tried to render the missing 'vueapp' layout -> HTTP 406.
  if ActiveModel::Type::Boolean.new.cast(ENV.fetch('EVOLUTION_API_ONLY_SERVER', true))
    root to: 'api#index'
  else
    root to: 'dashboard#index'

    get '/app', to: 'dashboard#index'
    get '/app/*params', to: 'dashboard#index'
    get '/app/settings/inboxes/new/twitter', to: 'dashboard#index', as: 'app_new_twitter_inbox'
    get '/app/settings/inboxes/new/microsoft', to: 'dashboard#index', as: 'app_new_microsoft_inbox'
    get '/app/settings/inboxes/new/instagram', to: 'dashboard#index', as: 'app_new_instagram_inbox'
    get '/app/settings/inboxes/new/whatsapp', to: 'dashboard#index', as: 'app_new_whatsapp_inbox'
    get '/app/settings/inboxes/new/:inbox_id/agents', to: 'dashboard#index', as: 'app_twitter_inbox_agents'
    get '/app/settings/inboxes/new/:inbox_id/agents', to: 'dashboard#index', as: 'app_email_inbox_agents'
    get '/app/settings/inboxes/new/:inbox_id/agents', to: 'dashboard#index', as: 'app_instagram_inbox_agents'
    get '/app/settings/inboxes/new/:inbox_id/agents', to: 'dashboard#index', as: 'app_whatsapp_inbox_agents'
    get '/app/settings/inboxes/:inbox_id', to: 'dashboard#index', as: 'app_instagram_inbox_settings'
    get '/app/settings/inboxes/:inbox_id', to: 'dashboard#index', as: 'app_email_inbox_settings'
  end

  ## Slack fetches these avatar/attachment URLs directly (not the SPA), so the route
  ## must exist even when the backend is API-only.
  resource :slack_uploads, only: [:show]

  get '/api', to: 'api#index'
  namespace :api, defaults: { format: 'json' } do
    namespace :v1 do
      namespace :admin do
        get 'app_configs/:config_type', to: 'app_configs#show', as: :app_config
        post 'app_configs/:config_type', to: 'app_configs#create', as: :app_configs
        post 'app_configs/:config_type/test_connection', to: 'app_configs#test_connection', as: :test_app_config_connection
        delete 'app_configs/:config_type', to: 'app_configs#destroy', as: :destroy_app_config
      end

      resource :global_config, controller: 'global_config', only: [:show]
      namespace :integrations do
        namespace :google_calendar do
          get 'credentials', to: 'credentials#show'
        end
        namespace :google_sheets do
          get 'credentials', to: 'credentials#show'
        end
        namespace :github do
          get 'credentials', to: 'credentials#show'
        end
        namespace :notion do
          get 'credentials', to: 'credentials#show'
        end
        namespace :linear do
          get 'credentials', to: 'credentials#show'
        end
        namespace :monday do
          get 'credentials', to: 'credentials#show'
        end
        namespace :atlassian do
          get 'credentials', to: 'credentials#show'
        end
        namespace :asana do
          get 'credentials', to: 'credentials#show'
        end
        namespace :hubspot do
          get 'credentials', to: 'credentials#show'
        end
        namespace :paypal do
          get 'credentials', to: 'credentials#show'
        end
        namespace :canva do
          get 'credentials', to: 'credentials#show'
        end
        namespace :supabase do
          get 'credentials', to: 'credentials#show'
        end
      end

      namespace :oauth do
        resources :applications, only: [:create]
        resources :authorization, only: [:create]
      end

      resource :dashboard, only: [], controller: 'dashboard' do
        get :customer
      end

      resources :inboxes, only: [:index, :show, :create, :update, :destroy], controller: 'inboxes' do
        get :assignable_agents, on: :member
        get :agent_bot, on: :member
        post :set_agent_bot, on: :member
        get :facebook_posts, on: :member
        post :setup_channel_provider, on: :member
        post :disconnect_channel_provider, on: :member
        post :sync_whatsapp_subscription, on: :member
        delete :avatar, on: :member
        # Template CRUD moved to the dedicated flat /api/v1/message_templates
        # endpoint (EVO-1716). Only the per-channel Meta sync stays inbox-scoped.
        post 'message_templates/sync', action: :sync_message_templates, on: :member
        post 'message_templates/:template_id/sync_with_whatsapp_cloud',
             action: :sync_template_with_whatsapp_cloud, on: :member
      end

      resources :conversations, only: [:index, :create, :show, :update, :destroy], controller: 'conversations' do
        resources :facebook_comment_moderations, only: [:index], controller: 'facebook_comment_moderations'
        collection do
          get :meta
          get :search
          post :filter
          get :available_for_pipeline
          get :unread_count
          post :import
        end
        resources :messages, only: [:index, :create, :destroy, :update], controller: 'conversations/messages' do
          member do
            post :retry
          end
        end
        resources :assignments, only: [:create], controller: 'conversations/assignments'
        resources :labels, only: [:create, :index], controller: 'conversations/labels'
        resource :participants, only: [:show, :create, :update, :destroy], controller: 'conversations/participants'
        resource :direct_uploads, only: [:create], controller: 'conversations/direct_uploads'
        resource :draft_messages, only: [:show, :update, :destroy], controller: 'conversations/draft_messages'
        member do
          post :mute
          post :unmute
          post :transcript
          post :email_team
          post :toggle_status
          post :return_to_bot
          post :toggle_priority
          post :toggle_typing_status
          post :update_last_seen
          post :unread
          post :custom_attributes
          post :pin
          post :unpin
          post :archive
          post :unarchive
          get :attachments
          get :inbox_assistant
        end
      end

      resources :teams, controller: 'teams' do
        resources :team_members, only: [:index, :create], controller: 'team_members' do
          collection do
            delete :destroy
            patch :update
          end
        end
      end

      resources :labels, only: [:index, :show, :create, :update, :destroy], controller: 'labels'

      resources :agent_bots, only: [:index, :create, :show, :update, :destroy], controller: 'agent_bots' do
        delete :avatar, on: :member
      end

      resources :canned_responses, only: [:index, :show, :create, :update, :destroy], controller: 'canned_responses'

      # Dedicated, account-scoped message templates CRUD (global + channel-bound).
      # Channel-bound ops pass inbox_id; Meta sync stays on the inbox routes. (EVO-1716)
      resources :message_templates, only: [:index, :show, :create, :update, :destroy], controller: 'message_templates'

      resources :facebook_comment_moderations, only: [:index, :show], controller: 'facebook_comment_moderations' do
        member do
          post :approve
          post :reject
          post :regenerate_response
        end
      end

      resources :notifications, only: [:index, :update, :destroy], controller: 'notifications' do
        collection do
          post :read_all
          get :unread_count
          post :destroy_all
        end
        member do
          post :snooze
          post :unread
        end
      end

      resource :notification_settings, only: [:show, :update], controller: 'notification_settings'

      resources :scheduled_actions, only: [:index, :show, :create, :update, :destroy], controller: 'scheduled_actions' do
        collection do
          get 'by_deal/:deal_id', action: :by_deal, as: :by_deal
          get 'by_contact/:contact_id', action: :by_contact, as: :by_contact
        end
      end

      resources :agents, only: [:index, :create, :update, :destroy], controller: 'agents' do
        post :bulk_create, on: :collection
      end

      resources :agent_bots, only: [:index, :create, :show, :update, :destroy], controller: 'agent_bots' do
        delete :avatar, on: :member
      end

      resources :contacts, only: [:index, :show, :update, :create, :destroy], controller: 'contacts' do
        collection do
          get :active
          get :search
          post :filter
          post :import
          post :export
          get :companies_list
        end
        member do
          get :contactable_inboxes
          post :destroy_custom_attributes
          delete :avatar
          get :companies
          get :pipelines
        end
        scope module: 'contacts' do
          resources :conversations, only: [:index]
          resources :contact_inboxes, only: [:create]
          resources :labels, only: [:create, :index]
          resources :notes
        end
      end

      resources :contact_companies, only: [:create, :destroy], path: 'contacts/:contact_id/companies', controller: 'contact_companies'
      resource :contact_bulk_transfer, only: [:create], path: 'contacts/bulk_transfer', controller: 'contact_bulk_transfers'

      scope module: 'evo_flow' do
        resources :contact_events, only: [:index], path: 'contacts/:contact_id/events', param: :contact_id
        resources :segments, only: %i[index show create update destroy] do
          member do
            post :recompute
            get :contact_ids, path: 'contact-ids'
          end
          collection do
            post :preview
            post :recompute_all, path: 'recompute-all'
          end
        end
      end

      resources :csat_survey_responses, only: [:index], controller: 'csat_survey_responses' do
        collection do
          get :metrics
          get :download
        end
      end

      resources :custom_attribute_definitions, only: [:index, :show, :create, :update, :destroy], controller: 'custom_attribute_definitions'
      resources :custom_filters, only: [:index, :show, :create, :update, :destroy], controller: 'custom_filters'

      resources :automation_rules, only: [:index, :create, :show, :update, :destroy], controller: 'automation_rules' do
        post :clone, on: :member
        get :runs, on: :member
      end

      # Product Catalog (EVO-1109)
      resources :products, only: [:index, :create, :show, :update, :destroy], controller: 'products' do
        # Bulk import endpoint (EVO-1555 S1)
        collection do
          post :bulk
        end
        resources :variants, controller: 'products/variants', only: [:index, :create, :update, :destroy]
      end

      # Lead-capture form builder admin CRUD (B14.01).
      resources :crm_forms, only: [:index, :create, :show, :update, :destroy], controller: 'crm_forms' do
        get :leads, on: :member
      end

      # Chat-page builder admin CRUD (B14.08).
      resources :chat_pages, only: [:index, :create, :show, :update, :destroy], controller: 'chat_pages'

      # ERP webhook ingress (EVO-1735 S3.0) — extensible adapter registry,
      # ships with `:noop` only. Adapter for a concrete ERP lands in S3.1
      # when a customer pilot is contracted.
      namespace :webhooks do
        post 'erp/:provider', to: 'erp#receive', as: :erp_webhook
      end

      # Attach/detach products to AI agents (agent lives in evo_core; we only
      # track the join here and propagate to agent.config via
      # Ai::AgentProductSyncService).
      resources :ai_agents, only: [] do
        resources :products, controller: 'ai_agents/products', only: [:index, :create, :destroy]
      end

      resources :macros, only: [:index, :create, :show, :update, :destroy], controller: 'macros' do
        post :execute, on: :member
      end

      resources :dashboard_apps, only: [:index, :show, :create, :update, :destroy], controller: 'dashboard_apps'

      resources :inbox_members, only: [:create, :show], param: :inbox_id, controller: 'inbox_members' do
        collection do
          delete :destroy
          patch :update
        end
      end

      resources :search, only: [:index], controller: 'search' do
        collection do
          get :conversations
          get :messages
          get :contacts
          get :articles
        end
      end

      resources :webhooks, only: [:index, :create, :update, :destroy], controller: 'webhooks' do
        # Public webhook endpoints that need accountId in URL for external services
        collection do
          # SMS webhooks
          post 'sms/twilio', to: 'webhooks/sms#process_payload'
          post 'sms/bandwidth', to: 'webhooks/sms#process_payload'
          post 'sms/:phone_number', to: 'webhooks/sms#process_payload'

          # WhatsApp webhooks
          get 'whatsapp', to: 'webhooks/whatsapp#verify'
          post 'whatsapp', to: 'webhooks/whatsapp#process_payload'
          get 'whatsapp/:phone_number', to: 'webhooks/whatsapp#verify'
          post 'whatsapp/:phone_number', to: 'webhooks/whatsapp#process_payload'
          post 'whatsapp/evolution', to: 'webhooks/whatsapp#process_payload'
          post 'whatsapp/evolution_go', to: 'webhooks/whatsapp#process_evolution_go_payload'
          post 'whatsapp/zapi', to: 'webhooks/whatsapp#process_payload'

          # Telegram webhooks
          post 'telegram/:bot_token', to: 'webhooks/telegram#process_payload'

          # Line webhooks
          post 'line/:line_channel_id', to: 'webhooks/line#process_payload'

          # Instagram webhooks
          get 'instagram', to: 'webhooks/instagram#verify'
          post 'instagram', to: 'webhooks/instagram#events'

          # Facebook webhooks
          post 'facebook/feed', to: 'webhooks/facebook#feed_events'

          # Twitter webhooks
          get 'twitter', to: 'api/v1/webhooks#twitter_crc'
          post 'twitter', to: 'api/v1/webhooks#twitter_events'

          # Gmail webhooks
          post 'gmail/pubsub', to: 'webhooks/gmail#pubsub'
        end
      end

      resources :assignable_agents, only: [:index], controller: 'assignable_agents'

      resources :contact_inboxes, only: [], controller: 'contact_inboxes' do
        collection do
          post :filter
        end
      end

      namespace :actions do
        resource :contact_merge, only: [:create], controller: 'contact_merges'
      end

      resource :bulk_actions, only: [:create], controller: 'bulk_actions'

      resources :callbacks, only: [], controller: 'callbacks' do
        collection do
          post :register_facebook_page
          get :register_facebook_page
          post :facebook_pages
          post :reauthorize_page
        end
      end

      scope path: 'channels', as: 'channels' do
        resource :twilio_channel, only: [:create], controller: 'channels/twilio_channels'
        post 'notificame/verify', to: 'channels/notificame_channels#verify', as: :notificame_verify
      end

      scope path: 'notificame', as: 'notificame' do
        resources :channels, only: [:index], controller: 'notificame/channels'
      end

      resources :facebook_comment_moderations, only: [:index, :show], controller: 'facebook_comment_moderations' do
        member do
          post :approve
          post :reject
          post :regenerate_response
        end
      end

      resources :working_hours, only: [:update], controller: 'working_hours'

      scope path: 'twitter', as: 'twitter' do
        resource :authorization, only: [:create], controller: 'twitter/authorizations'
      end

      scope path: 'microsoft', as: 'microsoft' do
        resource :authorization, only: [:create], controller: 'microsoft/authorizations'
        post :callback, to: 'microsoft/authorizations#callback'
      end

      scope path: 'google', as: 'google' do
        resource :authorization, only: [:create], controller: 'google/authorizations'
        post :callback, to: 'google/authorizations#callback'
      end

      scope path: 'instagram', as: 'instagram' do
        resource :authorization, only: [:create], controller: 'instagram/authorizations'
        post :callback, to: 'instagram/authorizations#callback'
      end

      scope path: 'whatsapp', as: 'whatsapp' do
        resource :authorization, only: [:create], controller: 'whatsapp/authorizations'
        resources :callback, only: [:index], controller: 'whatsapp/callbacks'
      end

      scope path: 'evolution', as: 'evolution' do
        get :health, to: 'evolution/health#show'
        resource :authorization, only: [:create], controller: 'evolution/authorizations'
        resources :qrcodes, only: [:create, :show], controller: 'evolution/qrcodes'
        resources :proxies, only: [:create, :show], controller: 'evolution/proxies'
        resources :settings, only: [:create, :show, :update], controller: 'evolution/settings'
        resources :privacy, only: [:show, :update], controller: 'evolution/privacy'
        resources :instances, only: [:index], controller: 'evolution/instances' do
          member do
            delete :logout
          end
        end
        post 'profile/:instance_name/fetch', to: 'evolution/profile#fetch', as: :profile_fetch
        post 'profile/:instance_name/name', to: 'evolution/profile#update_name', as: :profile_update_name
        post 'profile/:instance_name/status', to: 'evolution/profile#update_status', as: :profile_update_status
        post 'profile/:instance_name/picture', to: 'evolution/profile#update_picture', as: :profile_update_picture
        delete 'profile/:instance_name/picture', to: 'evolution/profile#remove_picture', as: :profile_remove_picture
      end

      scope path: 'evolution_go', as: 'evolution_go' do
        resource :authorization, only: [:create], controller: 'evolution_go/authorizations' do
          collection do
            post :connect
            get :qrcode
            get :fetch
            delete :logout
            delete :delete_instance
          end
        end
        resources :settings, only: [:show, :update], controller: 'evolution_go/settings'
        resources :qrcodes, only: [:show, :create], controller: 'evolution_go/qrcodes'
        resources :privacy, only: [:show, :update], controller: 'evolution_go/privacy'
        post 'profile/info', to: 'evolution_go/profile#info', as: :profile_info
        post 'profile/avatar', to: 'evolution_go/profile#avatar', as: :profile_avatar
        post 'profile/picture', to: 'evolution_go/profile#update_picture', as: :profile_update_picture
        get 'profile/:id', to: 'evolution_go/profile#show', as: :profile_show
        post 'profile/:id/name', to: 'evolution_go/profile#update_name', as: :profile_update_name
        post 'profile/:id/status', to: 'evolution_go/profile#update_status', as: :profile_update_status
        post 'profile/:id/picture', to: 'evolution_go/profile#update_picture_by_instance', as: :profile_update_picture_by_instance
        delete 'profile/:id/picture', to: 'evolution_go/profile#remove_picture', as: :profile_remove_picture
      end

      scope path: 'zapi', as: 'zapi' do
        resources :qrcodes, only: [:show, :create], controller: 'zapi/qrcodes' do
          collection do
            get :status
          end
        end
        post 'qrcodes/:id', to: 'zapi/qrcodes#refresh', as: :qrcode_refresh
        resources :settings, only: [:show], controller: 'zapi/settings' do
          member do
            put :update_profile_picture
            put :update_profile_name
            put :update_profile_description
            put :update_instance_name
            put :update_call_reject
            put :update_call_reject_message
            post :restart
            post :disconnect
            get :privacy_disallowed_contacts
            post :privacy_set_last_seen
            post :privacy_set_photo_visualization
            post :privacy_set_description
            post :privacy_set_group_add_permission
            post :privacy_set_online
            post :privacy_set_read_receipts
            post :privacy_set_messages_duration
          end
        end
      end

      namespace :oauth do
        resources :applications do
          member do
            post :regenerate_secret
          end
        end
      end

      namespace :integrations do
        resources :apps, only: [:index, :show], controller: '/api/v1/integrations/apps'
        post 'openai/process_event', to: '/api/v1/integrations/openai#process_event'
        resource :slack, only: [:create, :update, :destroy] do
          member do
            get :list_all_channels
          end
        end
        resource :dyte, only: [] do
          collection do
            post :create_a_meeting
            post :add_participant_to_meeting
          end
        end
        resource :shopify, only: [:destroy] do
          collection do
            post :auth
            get :orders
          end
        end
        resource :linear, only: [] do
          collection do
            delete :destroy
            get :teams
            get :team_entities
            post :create_issue
            post :link_issue
            post :unlink_issue
            get :search_issue
            get :linked_issues
          end
        end
        resource :hubspot, only: [] do
          collection do
            delete :destroy
            get :pipelines
            get :pipeline_stages
            get :owners
            post :create_deal
            post :link_deal
            post :unlink_deal
            get :search_deals
            get :linked_deals
          end
        end
      end

      scope :integrations, as: :integrations do
        resources :hooks, only: [:show, :create, :update, :destroy], controller: 'integrations/hooks' do
          member do
            post :process_event
          end
        end
      end

      resources :upload, only: [:create], controller: 'uploads'

      resources :templates, controller: 'templates', only: [] do
        collection do
          get :exportable_inventory
          post :export
          post :import
        end
      end

      post 'pipeline_tasks/for_conversation', to: 'pipeline_tasks#for_conversation'

      resources :pipelines, controller: 'pipelines' do
        collection do
          get :stats
          get 'by_conversation/:conversation_id', action: :by_conversation, as: :by_conversation
          get 'by_contact/:contact_id', action: :by_contact, as: :by_contact
        end
        member do
          patch :archive
          patch :set_as_default
          get :stats
        end
        resources :pipeline_stages, except: [:new, :edit], controller: 'pipeline_stages' do
          member do
            patch :move_up
            patch :move_down
            post :bulk_move_conversations
          end
          collection do
            patch :reorder
          end
        end
        resources :pipeline_items, except: [:new, :edit], controller: 'pipeline_items' do
          member do
            patch :move_to_stage
            patch :update_custom_fields
            patch :update_conversation
          end
          collection do
            patch :bulk_move
            patch :move_conversation
            get :stats
            get :available_conversations
            get :available_contacts
          end
          resources :tasks, controller: 'pipeline_tasks', only: [:index, :create]
          resources :products, controller: 'pipeline_items/products', only: [:index, :create, :update, :destroy]
        end
        resources :pipeline_tasks, only: [:show, :update, :destroy], controller: 'pipeline_tasks' do
          member do
            post :complete
            post :cancel
            post :reopen
            post :add_subtask
            patch :move
            patch :reorder
          end
          collection do
            get :statistics
          end
        end
        resources :pipeline_service_definitions, except: [:new, :edit], controller: 'pipeline_service_definitions'
      end

      namespace :integrations do
        resources :webhooks, only: [:create]

        # Evolution Hub — proxy autenticado pra endpoints do user no Hub.
        # Frontend usa pra renderizar dropdown de Meta Apps disponíveis
        # antes de criar canal (decisão shared vs BYO) e pra preview de
        # configuração detectada na tela Admin → Evolution Hub.
        resource :evolution_hub, controller: 'evolution_hub', only: [] do
          collection do
            get :meta_app_options
            get :plan
            get :channels
            get :available_channels
          end
        end
      end

      resource :profile, only: [:show, :update] do
        delete :avatar, on: :collection
        member do
          post :availability
          post :auto_offline
        end
      end

      resource :notification_subscriptions, only: [:create, :destroy]

      resources :user_tours, only: [:index, :create, :destroy], param: :tour_key

      namespace :widget do
        resource :direct_uploads, only: [:create]
        resource :config, only: [:create]
        resources :events, only: [:create]
        resources :messages, only: [:index, :create, :update]
        resources :conversations, only: [:index, :create] do
          collection do
            post :destroy_custom_attributes
            post :set_custom_attributes
            post :update_last_seen
            post :toggle_typing
            post :transcript
            get  :toggle_status
          end
        end
        resource :contact, only: [:show, :update] do
          collection do
            post :destroy_custom_attributes
            patch :set_user
          end
        end
        resources :inbox_members, only: [:index]
        resources :labels, only: [:create, :destroy]
        namespace :integrations do
          resource :dyte, controller: 'dyte', only: [] do
            collection do
              post :add_participant_to_meeting
            end
          end
        end
      end
    end

    namespace :v2 do
      resources :summary_reports, only: [], controller: 'summary_reports' do
        collection do
          get :agent
          get :team
          get :inbox
        end
      end
      resources :reports, only: [:index], controller: 'reports' do
        collection do
          get :summary
          get :bot_summary
          get :agents
          get :inboxes
          get :labels
          get :teams
          get :conversations
          get :conversation_traffic
          get :bot_metrics
        end
      end
      resources :live_reports, only: [], controller: 'live_reports' do
        collection do
          get :conversation_metrics
          get :grouped_conversation_metrics
        end
      end
    end
  end

  namespace :public, defaults: { format: 'json' } do
    namespace :api do
      namespace :v1 do
        resources :inboxes do
          scope module: :inboxes do
            resources :contacts, only: [:create, :show, :update] do
              resources :conversations, only: [:index, :create, :show] do
                member do
                  post :toggle_status
                  post :toggle_typing
                  post :update_last_seen
                end

                resources :messages, only: [:index, :create, :update]
                # Dedicated outbound send: creates an :outgoing message, optionally
                # rendered from a MessageTemplate (EVO-1235 [6.6]).
                resources :outbound_messages, only: [:create]
              end
            end
          end
        end

        resources :leads, only: [:create]

        # Anonymous lead-capture forms (B14.01): resolved by public slug, no API key.
        get  'forms/:slug',             to: 'forms#show'
        post 'forms/:slug/submissions', to: 'forms#create'

        # Anonymous public chat page (B14.03): resolved by slug, returns website_token.
        get 'chat_pages/:slug', to: 'chat_pages#show'

        resources :csat_survey, only: [:show, :update]
      end
    end
  end

  mount Facebook::Messenger::Server, at: 'bot'
  post 'webhooks/facebook/feed', to: 'webhooks/facebook#feed_events'
  get 'webhooks/twitter', to: 'api/v1/webhooks#twitter_crc'
  post 'webhooks/twitter', to: 'api/v1/webhooks#twitter_events'
  post 'webhooks/line/:line_channel_id', to: 'webhooks/line#process_payload'
  post 'webhooks/telegram/:bot_token', to: 'webhooks/telegram#process_payload'
  post 'webhooks/sms/:phone_number', to: 'webhooks/sms#process_payload'
  post 'webhooks/gmail/pubsub', to: 'webhooks/gmail#pubsub'
  post 'webhooks/sendgrid', to: 'webhooks/sendgrid#create'
  get 'webhooks/whatsapp', to: 'webhooks/whatsapp#verify'
  post 'webhooks/whatsapp', to: 'webhooks/whatsapp#process_payload'
  get 'webhooks/whatsapp/:phone_number', to: 'webhooks/whatsapp#verify'
  post 'webhooks/whatsapp/:phone_number', to: 'webhooks/whatsapp#process_payload'
  get 'webhooks/instagram', to: 'webhooks/instagram#verify'
  post 'webhooks/instagram', to: 'webhooks/instagram#events'
  post 'webhooks/whatsapp/evolution', to: 'webhooks/whatsapp#process_payload'
  post 'webhooks/whatsapp/evolution_go', to: 'webhooks/whatsapp#process_evolution_go_payload'
  post 'webhooks/whatsapp/zapi', to: 'webhooks/whatsapp#process_payload'
  post 'webhooks/evolution_hub', to: 'webhooks/evolution_hub#create'

  # Bot Runtime postback
  post 'webhooks/bot_runtime/postback/:conversation_display_id', to: 'webhooks/bot_runtime#postback'

  namespace :twitter do
    resource :callback, only: [:show]
  end

  namespace :linear do
    resource :callback, only: [:show]
  end

  namespace :hubspot do
    resource :callback, only: [:show]
  end

  namespace :shopify do
    resource :callback, only: [:show]
  end

  namespace :twilio do
    resources :callback, only: [:create]
    resources :delivery_status, only: [:create]
  end

  get 'microsoft/callback', to: 'microsoft/callbacks#show'
  get 'google/callback', to: 'google/callbacks#show'
  get 'instagram/callback', to: 'instagram/callbacks#show'
  get 'whatsapp/callback', to: 'whatsapp/callbacks#show'
  get '.well-known/assetlinks.json' => 'android_app#assetlinks'
  get '.well-known/apple-app-site-association' => 'apple_app#site_association'
  get '.well-known/microsoft-identity-association.json' => 'microsoft#identity_association'

  require 'sidekiq/web'
  require 'sidekiq/cron/web'

  # Enterprise / consumer plugins mount their routes through the plugin_loader
  # extension point. No-op in the community release — the registry is empty
  # unless a consumer gem registers a plugin. See EXTENSION_POINTS.md §3.
  EvoExtensionPoints::PluginLoader.draw_routes(self)
end
