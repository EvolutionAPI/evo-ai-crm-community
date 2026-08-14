# frozen_string_literal: true

# Validates the id params of a macro action before delegating to the shared
# conversation handlers, which return silently on an unresolved id (CRM-54).
#
# Deliberately NOT in AutomationRules::ConversationActionHandlers: that handler
# also backs automation rules, journeys and pipelines, where applying a label by
# NAME is intentional (EVO-1932).
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

  # Mirrors the unassign branch of the shared handler: only a real assignment
  # is validated, so the "clear the team" macro keeps working.
  def unassign_team?(team_ids)
    team_ids.blank? || %w[nil 0].include?(team_ids[0].to_s)
  end

  # The macro form only offers a picker over registered labels, so a non-uuid
  # here is corruption, not a title: passing it through tags the conversation
  # with a label that exists nowhere in the account.
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
