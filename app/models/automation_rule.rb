# == Schema Information
#
# Table name: automation_rules
#
#  id          :uuid             not null, primary key
#  actions     :jsonb            not null
#  active      :boolean          default(TRUE), not null
#  conditions  :jsonb            not null
#  description :text
#  event_name  :string           not null
#  flow_data   :jsonb
#  mode        :string           default("simple"), not null
#  name        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
# Indexes
#
#  index_automation_rules_on_flow_data  (flow_data) USING gin
#  index_automation_rules_on_mode       (mode)
#
class AutomationRule < ApplicationRecord
  include Rails.application.routes.url_helpers
  include Reauthorizable

  has_many_attached :files
  has_many :runs, class_name: 'AutomationRuleRun', dependent: :delete_all

  validate :json_conditions_format
  validate :json_actions_format
  validate :json_flow_data_format
  validate :query_operator_presence
  validate :query_operator_value
  validates :mode, inclusion: { in: %w[simple flow] }

  after_update_commit :reauthorized!, if: -> { saved_change_to_conditions? }

  scope :active, -> { where(active: true) }
  scope :simple_mode, -> { where(mode: 'simple') }
  scope :flow_mode, -> { where(mode: 'flow') }

  def conditions_attributes
    %w[content email country_code status message_type browser_language assignee_id team_id referer city company inbox_id
       mail_subject phone_number priority conversation_language pipeline_id pipeline_stage_id labels name identifier blocked]
  end

  def actions_attributes
    %w[send_message send_canned_response send_template add_label remove_label send_email_to_team assign_team assign_agent
       send_webhook_event mute_conversation send_attachment change_status resolve_conversation snooze_conversation
       change_priority send_email_transcript assign_to_pipeline update_pipeline_stage create_pipeline_task
       update_custom_attribute].freeze
  end

  def file_base_data
    files.map do |file|
      {
        id: file.id,
        automation_rule_id: id,
        file_type: file.content_type,
        file_url: url_for(file),
        blob_id: file.blob_id,
        filename: file.filename.to_s
      }
    end
  end

  def flow_data_valid?
    return true if mode != 'flow' || flow_data.nil?
    
    required_keys = %w[nodes edges variables]
    required_keys.all? { |key| flow_data.key?(key) || flow_data.key?(key.to_sym) }
  end

  private

  def json_flow_data_format
    return if mode != 'flow'
    
    if flow_data.nil?
      errors.add(:flow_data, 'Flow data is required for flow mode automations')
      return
    end
    
    unless flow_data.is_a?(Hash)
      errors.add(:flow_data, 'Flow data must be a valid JSON object')
      return
    end
    
    required_keys = %w[nodes edges variables]
    flow_data_keys = flow_data.keys.map(&:to_s)
    missing_keys = required_keys - flow_data_keys
    
    if missing_keys.any?
      errors.add(:flow_data, "Flow data must contain: #{missing_keys.join(', ')}")
    end
    
    # Validate nodes structure
    nodes = flow_data[:nodes] || flow_data['nodes']
    if nodes.present? && !nodes.is_a?(Array)
      errors.add(:flow_data, 'Nodes must be an array')
    end
    
    # Validate edges structure  
    edges = flow_data[:edges] || flow_data['edges']
    if edges.present? && !edges.is_a?(Array)
      errors.add(:flow_data, 'Edges must be an array')
    end
    
    # Validate variables structure
    variables = flow_data[:variables] || flow_data['variables']
    if variables.present? && !variables.is_a?(Array)
      errors.add(:flow_data, 'Variables must be an array')
    end
  end

  def json_conditions_format
    return if conditions.blank?

    attributes = conditions.map { |obj, _| obj['attribute_key'] }
    conditions = attributes - conditions_attributes
    conditions -= CustomAttributeDefinition.pluck(:attribute_key)
    errors.add(:conditions, "Automation conditions #{conditions.join(',')} not supported.") if conditions.any?
  end

  def json_actions_format
    return if actions.blank?

    attributes = actions.map { |obj, _| obj['action_name'] }
    actions = attributes - actions_attributes

    errors.add(:actions, "Automation actions #{actions.join(',')} not supported.") if actions.any?
  end

  def query_operator_presence
    return if conditions.blank?

    operators = conditions.select { |obj, _| obj['query_operator'].nil? }
    errors.add(:conditions, 'Automation conditions should have query operator.') if operators.length > 1
  end

  # This validation ensures logical operators are being used correctly in automation conditions.
  # And we don't push any unsanitized query operators to the database.
  def query_operator_value
    conditions.each do |obj|
      validate_single_condition(obj)
    end
  end

  def validate_single_condition(condition)
    query_operator = condition['query_operator']

    return if query_operator.nil?
    return if query_operator.empty?

    operator = query_operator.upcase
    errors.add(:conditions, 'Query operator must be either "AND" or "OR"') unless %w[AND OR].include?(operator)
  end
end

AutomationRule.prepend_mod_with('AutomationRule')
