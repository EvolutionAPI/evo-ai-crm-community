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
      resources :inventory_items
      # Configurações de menu por usuário (Editor/Sites/Dashboard) — persistência server-side
      scope 'menu_configs', as: 'menu_configs' do
        get ':scope', to: 'menu_configs#show'
        put ':scope', to: 'menu_configs#update'
      end
      resources :financial_transactions
      resources :recurring_transactions, only: [:index, :create, :update, :destroy]
      post 'finances/receipt_extractions', to: 'finances/receipt_extractions#create'
      get 'finances/receipt_extractions/providers', to: 'finances/receipt_extractions#providers'

      get 'marketing/gtm/accounts', to: 'marketing/gtm#accounts'
      get 'marketing/gtm/accounts/:account_id/containers', to: 'marketing/gtm#containers'
      post 'marketing/gtm/accounts/:account_id/containers', to: 'marketing/gtm#create_container'
      get 'marketing/gtm/accounts/:account_id/containers/:container_id/workspace', to: 'marketing/gtm#workspace'
      post 'marketing/gtm/accounts/:account_id/containers/:container_id/import', to: 'marketing/gtm#import_container'

      post 'marketing/gtm/accounts/:account_id/containers/:container_id/:resource',
           to: 'marketing/gtm#create_resource'
      put 'marketing/gtm/accounts/:account_id/containers/:container_id/:resource/:resource_id',
          to: 'marketing/gtm#update_resource'
      delete 'marketing/gtm/accounts/:account_id/containers/:container_id/:resource/:resource_id',
             to: 'marketing/gtm#destroy_resource'

      get 'marketing/gtm/accounts/:account_id/permissions', to: 'marketing/gtm#permissions'
      post 'marketing/gtm/accounts/:account_id/permissions', to: 'marketing/gtm#create_permission'
      delete 'marketing/gtm/accounts/:account_id/permissions/:permission_id', to: 'marketing/gtm#destroy_permission'
      resources :work_orders
      scope :ifood, as: :ifood do
        get '/status', to: 'ifood#status'
        get '/orders', to: 'ifood#index'
        post '/orders/sync', to: 'ifood#sync'
        post '/orders/:id/confirm', to: 'ifood#confirm'
        post '/orders/:id/start_preparation', to: 'ifood#start_preparation'
        post '/orders/:id/ready_to_pickup', to: 'ifood#ready_to_pickup'
        post '/orders/:id/dispatch', to: 'ifood#dispatch_order'
        post '/orders/:id/cancel', to: 'ifood#cancel'
        post '/orders/:id/request_driver', to: 'ifood#request_driver'
        post '/orders/:id/cancel_request_driver', to: 'ifood#cancel_request_driver'
        post '/disputes/:dispute_id/accept', to: 'ifood#accept_dispute'
        post '/disputes/:dispute_id/reject', to: 'ifood#reject_dispute'
        get '/interruptions', to: 'ifood#interruptions'
        post '/interruptions', to: 'ifood#create_interruption'
        delete '/interruptions/:id', to: 'ifood#destroy_interruption'
        get '/merchants', to: 'ifood#merchants'
        get '/merchant_details', to: 'ifood#merchant_details'
        post '/close', to: 'ifood#close_store'
        post '/open', to: 'ifood#open_store'
        get '/categories', to: 'ifood#categories'
        post '/categories', to: 'ifood#create_category'
        patch '/categories/:id', to: 'ifood#update_category'
        delete '/categories/:id', to: 'ifood#destroy_category'
        get '/products', to: 'ifood#products'
        post '/products', to: 'ifood#create_product'
        post '/items', to: 'ifood#create_item'
        get '/menu_items', to: 'ifood#menu_items'
        patch '/menu_items/:item_id', to: 'ifood#update_menu_item'
        delete '/menu_items/:item_id', to: 'ifood#destroy_menu_item'
        get '/delivery_quote', to: 'ifood#delivery_quote'
        get '/orders/:id/delivery_quote', to: 'ifood#delivery_quote_for_order'
        get '/settlements', to: 'ifood#settlements'
        get '/sales', to: 'ifood#sales'
        get '/reconciliation', to: 'ifood#reconciliation'
        get '/anticipations', to: 'ifood#anticipations'
        get '/financial_events', to: 'ifood#financial_events'
        get '/reviews', to: 'ifood#reviews'
        get '/review_summary', to: 'ifood#review_summary'
        post '/reviews/:id/reply', to: 'ifood#reply_review'
        get '/analytics', to: 'ifood#analytics'
        get '/opening_hours', to: 'ifood#opening_hours'
        put '/opening_hours', to: 'ifood#update_opening_hours'
      end
      namespace :admin do
        get 'app_configs/:config_type', to: 'app_configs#show', as: :app_config
        post 'app_configs/:config_type', to: 'app_configs#create', as: :app_configs
        post 'app_configs/:config_type/test_connection', to: 'app_configs#test_connection', as: :test_app_config_connection
        delete 'app_configs/:config_type', to: 'app_configs#destroy', as: :destroy_app_config
      end

      # Server-side proxy for the Marketing AI tools — keeps ElevenLabs/Groq/
      # Gemini/Hugging Face keys out of the browser (see ToolsProxyController).
      # `scope` (not `namespace`) so the controller stays Api::V1::ToolsProxyController
      # — no extra module nesting from the `tools_proxy/` path prefix.
      scope path: 'tools_proxy', controller: 'tools_proxy' do
        post 'elevenlabs/text_to_speech', action: :elevenlabs_text_to_speech
        post 'groq/chat_completions', action: :groq_chat_completions
        post 'openai/chat_completions', action: :openai_chat_completions
        post 'gemini/generate_content', action: :gemini_generate_content
        post 'huggingface/infer', action: :huggingface_infer
        get 'groq/models', action: :groq_models
        get 'openai/models', action: :openai_models
        get 'gemini/models', action: :gemini_models
      end

      # Relatórios do Dashboard (Meta Ads + Leads + Google Ads + Analytics)
      # sem depender do n8n — ver Meta::AdsInsightsService,
      # Google::AdsInsightsService, Google::AnalyticsInsightsService.
      namespace :reports do
        get 'meta_ads/insights', to: 'meta_ads#insights'
        get 'meta_ads/campaigns', to: 'meta_ads#campaigns'
        get 'meta_ads/accounts', to: 'meta_ads#accounts'
        get 'meta_ads/business_managers', to: 'meta_ads#business_managers'
        get 'google_ads/insights', to: 'google_ads#insights'
        get 'analytics/properties', to: 'analytics#properties'
        get 'analytics/overview', to: 'analytics#overview'
        get 'analytics/by_channel', to: 'analytics#by_channel'
        post 'meta_ads_manager', to: 'meta_ads_manager#handle'
        post 'meta_infrastructure', to: 'meta_infrastructure#handle'
        post 'ga4_infrastructure', to: 'ga4_infrastructure#handle'
        post 'ads_infrastructure', to: 'ads_infrastructure#handle'
        post 'google_calendar', to: 'google_calendar#handle'
        resources :whatsapp_ad_leads, only: [:index, :update]
      end

      resource :global_config, controller: 'global_config', only: [:show]
      get 'ai_credentials/migration_state', to: 'ai_credentials#migration_state'
      namespace :integrations do
        # Session-authed availability probe: booleans only (is each provider's OAuth
        # credential configured?), never the secret itself. See AvailabilityController.
        get 'availability', to: 'availability#index'
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
        # Discards a Hub connection that never completed. A separate door from
        # destroy because only this one refuses an already-connected channel.
        delete 'hub_connection', action: :abort_hub_connection, on: :member
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
          get :unanswered_count
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

        # EVO-2188: generic passthrough proxy to evo-flow's /journeys* surface
        # (create/list/update PATCH/delete/toggle-active/sessions/...). The frontend
        # journey builder hits /api/v1/journeys*; without this it gets 404/405.
        match 'journeys(/*path)', to: 'journeys#proxy',
              via: %i[get post put patch delete], format: false
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
          # Fetch products from a remote store (Shopify/WooCommerce)
          post :import_fetch
        end
        resources :variants, controller: 'products/variants', only: [:index, :create, :update, :destroy]
        post :sell, on: :member
      end

      # Product categories (catalog, autocomplete + create from the product modal).
      resources :product_categories, only: [:index, :create], controller: 'product_categories'

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
        # Purchase webhook ingress (lead capture): an approved purchase from a
        # registered payment platform becomes contact + pipeline card.
        post 'purchases/:provider', to: 'purchases#receive', as: :purchase_webhook
        post 'ninety_nine/:token', to: 'ninety_nine#receive', as: :ninety_nine_webhook
      end

      scope :ninety_nine, as: :ninety_nine do
        get '/webhook_info', to: 'ninety_nine#webhook_info'
        get '/orders', to: 'ninety_nine#index'
        get '/partner/status', to: 'ninety_nine/partner#status'
        get '/partner/connect_url', to: 'ninety_nine/partner#connect_url'
        get '/partner/bound_stores', to: 'ninety_nine/partner#bound_stores'
        get '/partner/store', to: 'ninety_nine/partner#store_details'
        post '/partner/store/status', to: 'ninety_nine/partner#set_store_status'
        get '/partner/menu', to: 'ninety_nine/partner#menu'
        post '/partner/menu/item_status', to: 'ninety_nine/partner#update_item_status'
        get '/partner/orders/:order_id', to: 'ninety_nine/partner#order_details'
        post '/partner/orders/:order_id/confirm', to: 'ninety_nine/partner#confirm_order'
        post '/partner/orders/:order_id/cancel', to: 'ninety_nine/partner#cancel_order'
        post '/partner/orders/:order_id/ready', to: 'ninety_nine/partner#ready_order'
        post '/partner/orders/:order_id/delivered', to: 'ninety_nine/partner#delivered_order'
        get '/partner/finance/bill', to: 'ninety_nine/partner#bill_data'
        get '/partner/finance/settlements', to: 'ninety_nine/partner#settlements_data'
      end

      scope :gestor_posts, as: :gestor_posts do
        get '/channels', to: 'gestor_posts/base#channels'
        get '/facebook_channels', to: 'gestor_posts/base#facebook_channels'
        get '/facebook_pages/accessible', to: 'gestor_posts/facebook_pages#accessible'
        post '/facebook_pages/connect', to: 'gestor_posts/facebook_pages#connect'
        get '/gallery/account_info', to: 'gestor_posts/gallery#account_info'
        get '/gallery/media', to: 'gestor_posts/gallery#media'
        get '/gallery/demographics', to: 'gestor_posts/gallery#demographics'
        get '/gallery/peak_hours', to: 'gestor_posts/gallery#peak_hours'
        get '/gallery/stories', to: 'gestor_posts/gallery#stories'
        delete '/gallery/media/:id', to: 'gestor_posts/gallery#destroy_media'
        get '/gallery/facebook_account_info', to: 'gestor_posts/gallery#facebook_account_info'
        get '/gallery/facebook_media', to: 'gestor_posts/gallery#facebook_media'
        delete '/gallery/facebook_media/:id', to: 'gestor_posts/gallery#destroy_facebook_media'
        get '/comments', to: 'gestor_posts/comments#index'
        post '/comments/reply', to: 'gestor_posts/comments#reply'
        get '/publications', to: 'gestor_posts/publications#index'
        get '/publications/:id', to: 'gestor_posts/publications#show'
        post '/publications', to: 'gestor_posts/publications#create'
        post '/carousel_uploads', to: 'gestor_posts/carousel_uploads#create'
        get '/carousel_uploads/:id', to: 'gestor_posts/carousel_uploads#show'
        post '/carousel_uploads/:id/cards', to: 'gestor_posts/carousel_uploads#add_card'
        get '/scheduled_posts', to: 'gestor_posts/scheduled_posts#index'
        post '/scheduled_posts', to: 'gestor_posts/scheduled_posts#create'
        post '/scheduled_posts/:id/cancel', to: 'gestor_posts/scheduled_posts#cancel'
        post '/scheduled_posts/:id/retry', to: 'gestor_posts/scheduled_posts#retry'
        get '/whatsapp_status/channels', to: 'gestor_posts/whatsapp_status#channels'
        post '/whatsapp_status', to: 'gestor_posts/whatsapp_status#create'
        get '/youtube/connected', to: 'gestor_posts/youtube#connected'
        get '/youtube/account_info', to: 'gestor_posts/youtube#account_info'
        get '/youtube/videos', to: 'gestor_posts/youtube#videos'
        post '/youtube', to: 'gestor_posts/youtube#create'
        get '/youtube/:id', to: 'gestor_posts/youtube#show'
      end

      # Authenticated CONFIG surface of the purchase-webhook ingress (CRM-493):
      # the pipeline screen lists the platforms and mints the signed URL the
      # operator registers at one. Deliberately outside `namespace :webhooks`
      # (that one is the unauthenticated delivery ingress).
      get 'purchase_webhooks/providers', to: 'purchase_webhooks#providers'
      get 'purchase_webhooks/url', to: 'purchase_webhooks#url'

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
          get 'twitter', to: '/api/v1/webhooks#twitter_crc'
          post 'twitter', to: '/api/v1/webhooks#twitter_events'

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

      scope path: 'microsoft', as: 'microsoft' do
        resource :authorization, only: [:create], controller: 'microsoft/authorizations'
        post :callback, to: 'microsoft/authorizations#callback'
      end

      scope path: 'google', as: 'google' do
        resource :authorization, only: [:create], controller: 'google/authorizations'
        post :callback, to: 'google/authorizations#callback'
      end

      # Fica FORA de `namespace :integrations` de propósito: o gateway nginx da VPS
      # tem uma regra ^/api/v1/integrations/[^/]+/callback que roteia pro processor
      # (callbacks OAuth de ferramentas de agente de IA) — um path aninhado aqui
      # colidiria e nunca chegaria no Rails. Mantém o padrão top-level já usado
      # por google/callback, microsoft/callback etc. acima.
      post 'google_workspace/callback', to: 'integrations/google_workspace_authorizations#callback'
      get 'google_ads/accessible_customers', to: 'integrations/google_ads_authorizations#accessible_customers'
      post 'google_ads/select_customer', to: 'integrations/google_ads_authorizations#select_customer'

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
          get :dependents
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
            get :connect_info
            post :whatsapp_connect
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

        # Cardápio digital — catálogo de produtos ativos, público, sem API key
        # (uma instalação = um catálogo, não precisa de slug).
        get 'menu', to: 'menu#show'
        post 'menu/orders', to: 'menu_orders#create'
        get 'menu/orders/:token/status', to: 'menu_orders#status'

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
  # EVO-2089: com WEBHOOK_BY_EVENTS=true a Evolution posta cada evento em
  # .../evolution/<evento> (ex.: messages-upsert). :sub_event (NAO :event — path
  # param sobrescreveria o `event` do corpo). Mesmo process_payload, que le o evento do corpo.
  post 'webhooks/whatsapp/evolution/:sub_event', to: 'webhooks/whatsapp#process_payload'
  post 'webhooks/whatsapp/evolution_go', to: 'webhooks/whatsapp#process_evolution_go_payload'
  post 'webhooks/whatsapp/zapi', to: 'webhooks/whatsapp#process_payload'
  post 'webhooks/evolution_hub', to: 'webhooks/evolution_hub#create'

  # Bot Runtime postback
  post 'webhooks/bot_runtime/postback/:conversation_display_id', to: 'webhooks/bot_runtime#postback'

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
