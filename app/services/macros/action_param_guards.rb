# frozen_string_literal: true

# Guard rails for the id params carried by a macro action.
#
# A macro's action_params always come from a picker in the form — never free
# text — so a value that does not resolve means the macro is stale or was saved
# corrupted (CRM-54). Until then those params went straight to
# AutomationRules::ConversationActionHandlers, which returns silently for the
# assignments and treats a non-uuid label as a title; either way the execution
# was reported as a success and the user got a green toast.
#
# The validation lives here and NOT in the shared handler on purpose: that
# handler is also the implementation behind automation rules, journeys and
# pipelines, where applying a label by NAME is intentional (EVO-1932).
module Macros::ActionParamGuards
  UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  class InvalidActionParam < StandardError; end

  private

  def assign_agent(agent_ids)
    agent_ids = Array(agent_ids).map { |id| id == 'self' ? @user.id : id }
    return super(agent_ids) if agent_ids.first.to_s == 'nil'

    agent_id = agent_ids.first
    raise_invalid_param('assign_agent', agent_id, 'not found') unless User.exists?(id: agent_id)
    return super(agent_ids) if agent_belongs_to_inbox?(agent_ids)

    raise_invalid_param('assign_agent', agent_id, "is not a member of inbox #{@conversation.inbox_id}")
  end

  def assign_team(team_ids)
    team_ids = Array(team_ids)
    return super(team_ids) if unassign_team?(team_ids)

    team_id = team_ids.first
    raise_invalid_param('assign_team', team_id, 'not found') unless Team.exists?(id: team_id)

    super(team_ids)
  end

  def add_label(labels)
    super(validated_label_ids(labels, 'add_label'))
  end

  def remove_label(labels)
    super(validated_label_ids(labels, 'remove_label'))
  end

  # Mirrors the unassign branch of the shared handler so the "clear the team"
  # macro keeps working — only a real assignment is validated.
  def unassign_team?(team_ids)
    team_ids.blank? || %w[nil 0].include?(team_ids[0].to_s)
  end

  # Inside a macro a label is always an id, so a non-uuid is corruption rather
  # than a title — passing it through would tag the conversation with a junk
  # label that exists nowhere in the account's label list.
  def validated_label_ids(labels, action_name)
    values = Array(labels).map(&:to_s).reject(&:empty?)
    return values if values.empty?

    malformed = values.grep_v(UUID_FORMAT)
    raise_invalid_param(action_name, malformed, 'is not a label id') if malformed.any?

    missing = values - Label.where(id: values).pluck(:id).map(&:to_s)
    raise_invalid_param(action_name, missing, 'not found') if missing.any?

    values
  end

  def raise_invalid_param(action_name, values, reason)
    raise InvalidActionParam, "#{action_name}: #{Array(values).map(&:inspect).join(', ')} #{reason}"
  end
end
