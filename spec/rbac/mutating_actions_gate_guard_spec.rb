# frozen_string_literal: true

require 'rails_helper'

# Guard-rail: every ROUTED mutating action (POST/PUT/PATCH/DELETE) under
# /api/v1 must be mapped in its controller's require_permissions (which
# defines check_<action>_permission!) or carry an explicit, justified entry
# below. A new controller/action without a gate fails this spec instead of
# shipping fully open — the root cause of the audited F1/F2 gaps.
RSpec.describe 'API v1 mutating actions permission guard' do
  MUTATING_VERBS = /POST|PUT|PATCH|DELETE/

  # Authenticated by a mechanism other than the per-user permission gate.
  EXEMPT_CONTROLLER_PREFIXES = %w[
    api/v1/widget/
    api/v1/webhooks
  ].freeze
  # widget/**   — contact-token/HMAC widget session, no CRM user.
  # webhooks/** — signature/token-verified inbound provider webhooks.

  EXEMPT_CONTROLLERS = {
    'api/v1/conversations/direct_uploads' => 'ActiveStorage subclass; conversation-scoped token flow',
    'api/v1/admin/app_configs' => 'Pundit-gated superadmin (Admin::BaseController before_action authorize :installation_config, :manage?)',
    'api/v1/inbox_members' => 'Pundit-gated per action (authorize @inbox, :create?/:update?/:destroy?)',
    'api/v1/profiles' => 'self-service: mutates only the authenticated user profile',
    'api/v1/notifications' => 'self-service: mutates only the caller notifications',
    'api/v1/notification_settings' => 'self-service: caller-scoped settings',
    'api/v1/notification_subscriptions' => 'self-service: caller-scoped push subscription',
    'api/v1/user_tours' => 'self-service: caller-scoped onboarding state'
  }.freeze

  EXEMPT_ACTIONS = {
    # OAuth handshakes: the provider redirect / client-credential exchange is
    # the credential, not a CRM user permission.
    'api/v1/microsoft/authorizations' => %w[callback],
    'api/v1/google/authorizations' => %w[callback],
    'api/v1/oauth/authorization' => %w[create],
    'api/v1/dynamic_oauth' => %w[validate_dynamic_client],
    # Type-aware dynamic gate (check_bulk_action_permission!): Conversation ->
    # conversations.update, Contact -> contacts.delete.
    'api/v1/bulk_actions' => %w[create],
    # Pundit-gated channel creation (authorize ::Inbox, :create?).
    'api/v1/channels/twilio_channels' => %w[create],
    'api/v1/channels/notificame_channels' => %w[verify],
    # Pundit-gated creation (authorize with the resource policy #create?),
    # matching how sibling update/destroy are authorized in these controllers.
    'api/v1/scheduled_actions' => %w[create],
    'api/v1/pipeline_tasks' => %w[create],
    # Pundit-gated on the parent pipeline (authorize @pipeline), three levels since
    # CRM-178: destroy at :update? (manager), other card writes at :update_items?
    # (agent), reads at :view?; skipped for service tokens.
    'api/v1/pipeline_items' =>
      %w[create update destroy bulk_move move_conversation move_to_stage update_conversation update_custom_fields],
    # POST-shaped reads inside the new-conversation flow.
    'api/v1/contact_inboxes' => %w[filter],
    'api/v1/contacts/contact_inboxes' => %w[create]
  }.freeze

  # Routes whose controller class does not exist: the request 500s on a
  # missing constant, so no user can reach the action. The Slack/HubSpot/
  # Linear/Shopify/Dyte panels route to pluralized controllers that were
  # never created — reviving them (controller: option + gates) is the
  # integrations follow-up's call. Anything NEW that lands here fails.
  KNOWN_DEAD_CONTROLLERS = %w[
    api/v1/integrations/slacks
    api/v1/integrations/hubspots
    api/v1/integrations/linears
    api/v1/integrations/shopifies
    api/v1/integrations/dytes
  ].freeze

  # Residual ungated mutations, kept visible instead of silently exempted.
  # Every entry is DEBT for the RBAC follow-up: shrink this list, never grow
  # it (a new entry means a new ungated endpoint shipped).
  PENDING_GATES = {
    'api/v1/integrations/webhooks' => %w[create],
    'api/v1/pipeline_tasks' => %w[update destroy move reorder add_subtask cancel complete reopen for_conversation],
    'api/v1/scheduled_actions' => %w[update destroy]
  }.freeze

  def service_authenticated?(controller_class)
    controller_class <= Api::ServiceController
  rescue NameError
    false
  end

  it 'gates every routed mutating action (or lists an explicit exemption)' do
    offenders = []

    Rails.application.routes.routes.each do |route|
      verb = route.verb.to_s
      next unless verb.match?(MUTATING_VERBS)

      controller = route.defaults[:controller]
      action = route.defaults[:action]
      next unless controller&.start_with?('api/v1')
      next if EXEMPT_CONTROLLER_PREFIXES.any? { |p| controller.start_with?(p) }
      next if EXEMPT_CONTROLLERS.key?(controller)
      next if EXEMPT_ACTIONS[controller]&.include?(action)
      next if PENDING_GATES[controller]&.include?(action)

      begin
        controller_class = "#{controller.camelize}Controller".constantize
      rescue NameError
        offenders << "#{verb} #{controller}##{action} (controller class missing)" unless KNOWN_DEAD_CONTROLLERS.include?(controller)
        next
      end

      next if service_authenticated?(controller_class)
      next if controller_class.instance_methods.include?(:"check_#{action}_permission!") ||
              controller_class.private_instance_methods.include?(:"check_#{action}_permission!")

      offenders << "#{verb} #{controller}##{action}"
    end

    expect(offenders.uniq.sort).to eq([])
  end

  it 'keeps the pending-gates debt list honest (entries must still be routed and ungated)' do
    stale = []

    PENDING_GATES.each do |controller, actions|
      controller_class = begin
        "#{controller.camelize}Controller".constantize
      rescue NameError
        stale << "#{controller} (controller gone)"
        next
      end

      actions.each do |action|
        if controller_class.instance_methods.include?(:"check_#{action}_permission!") ||
           controller_class.private_instance_methods.include?(:"check_#{action}_permission!")
          stale << "#{controller}##{action} (now gated — remove from PENDING_GATES)"
        end
      end
    end

    expect(stale).to eq([])
  end
end
