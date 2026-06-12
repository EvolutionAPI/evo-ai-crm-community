# frozen_string_literal: true

# Authorization for the dedicated, account-scoped message templates endpoint
# (Api::V1::MessageTemplatesController). Templates are an instance-wide catalog
# (no account_id column; global names are unique via a partial index), so access
# is gated purely by role/permission — there is no per-record account scoping.
#
# The `require_permissions` before_action is the primary 403 gate; this policy is
# defense-in-depth and mirrors InboxPolicy's template predicates. Before EVO-1716
# the global template path skipped the Pundit policy entirely (it relied only on
# `inboxes.message_templates`); the dedicated resource closes that gap. (EVO-1716)
class MessageTemplatePolicy < ApplicationPolicy
  # No Pundit Scope: templates are an instance-wide catalog with no per-record
  # account scoping, and the controller never calls policy_scope (it filters via
  # base_scope on inbox_id). A Scope class here would be dead code.

  def index?
    permitted?('message_templates.read')
  end

  def show?
    permitted?('message_templates.read')
  end

  def create?
    permitted?('message_templates.create')
  end

  def update?
    permitted?('message_templates.update')
  end

  def destroy?
    permitted?('message_templates.delete')
  end

  private

  def permitted?(permission)
    return true if service_authenticated?

    @user&.administrator? || @user&.has_permission?(permission)
  end
end
