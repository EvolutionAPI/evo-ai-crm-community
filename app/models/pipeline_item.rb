# == Schema Information
#
# Table name: pipeline_items
#
#  id                :uuid             not null, primary key
#  completed_at      :datetime
#  custom_fields     :jsonb
#  entered_at        :datetime
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  assigned_by_id    :uuid
#  contact_id        :uuid
#  conversation_id   :uuid
#  pipeline_id       :uuid             not null
#  pipeline_stage_id :uuid             not null
#
# Indexes
#
#  idx_pipeline_items_active_contact_per_pipeline       (contact_id,pipeline_id) UNIQUE WHERE ((conversation_id IS NULL) AND (completed_at IS NULL))
#  idx_pipeline_items_active_conversation_per_pipeline  (conversation_id,pipeline_id) UNIQUE WHERE ((conversation_id IS NOT NULL) AND (completed_at IS NULL))
#  index_pipeline_items_on_contact_id                   (contact_id)
#  index_pipeline_items_on_custom_fields                (custom_fields) USING gin
#  index_pipeline_items_on_pipeline_id                  (pipeline_id)
#  index_pipeline_items_on_pipeline_stage_id            (pipeline_stage_id)
#
# Foreign Keys
#
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (pipeline_id => pipelines.id)
#  fk_rails_...  (pipeline_stage_id => pipeline_stages.id)
#
class PipelineItem < ApplicationRecord
  include Wisper::Publisher

  belongs_to :pipeline
  belongs_to :pipeline_stage
  belongs_to :conversation, optional: true
  belongs_to :contact, optional: true
  belongs_to :assigned_by, class_name: 'User', optional: true

  has_many :stage_movements, dependent: :destroy
  has_many :tasks, class_name: 'PipelineTask', dependent: :destroy
  has_many :pipeline_item_products, dependent: :destroy
  has_many :products, through: :pipeline_item_products
  has_many :product_variants, through: :pipeline_item_products

  validates :conversation_id, uniqueness: { scope: :pipeline_id, conditions: -> { where(completed_at: nil) },
                                            message: 'already has an active journey in this pipeline' }, allow_nil: true
  validates :contact_id, uniqueness: { scope: :pipeline_id, conditions: -> { where(completed_at: nil) },
                                       message: 'already has an active journey in this pipeline' }, allow_nil: true
  validate :must_have_conversation_or_contact
  validate :validate_custom_fields_structure

  before_save :normalize_services_data!
  after_create :create_entry_movement
  # `_commit` so the Wisper publish + dispatcher dispatch (and the Sidekiq job
  # they enqueue) only fire after the transaction commits — avoids orphan jobs
  # on rollback.
  after_create_commit :publish_pipeline_item_created
  after_create :dispatch_initial_stage_event
  # EVO-1266: Wisper broadcast for journey-trigger consumption is
  # post-commit so rollbacks don't leak orphan Sidekiq jobs (mirrors
  # publish_pipeline_item_created above). The pre-commit
  # `dispatch_initial_stage_event` / `create_stage_change_movement`
  # below keep firing the legacy `Rails.configuration.dispatcher`
  # event for AutomationRules — its in-transaction execution is an
  # AC of that pre-existing path.
  after_create_commit :broadcast_stage_update_to_evo_flow
  after_update :create_stage_change_movement, if: :saved_change_to_pipeline_stage_id?
  after_update_commit :broadcast_stage_update_to_evo_flow, if: :saved_change_to_pipeline_stage_id?
  after_update :publish_pipeline_item_updated
  after_update :publish_pipeline_item_completed, if: :saved_change_to_completed_at?
  after_destroy :publish_pipeline_item_deleted

  scope :in_stage, ->(stage) { where(pipeline_stage: stage) }
  scope :active, -> { where(completed_at: nil) }
  scope :completed, -> { where.not(completed_at: nil) }

  def move_to_stage(new_stage, _moved_by = nil)
    return false if new_stage.pipeline != pipeline

    pipeline_stage
    self.pipeline_stage = new_stage

    save!

    # The movement will be created automatically by the after_update callback
    true
  end

  def days_in_pipeline
    end_time = completed_at || Time.current
    ((end_time - entered_at) / 1.day).round
  end

  def days_in_current_stage
    last_movement = stage_movements.order(:created_at).last
    start_time = last_movement&.created_at || entered_at
    ((Time.current - start_time) / 1.day).round
  end

  def completed?
    completed_at.present?
  end

  def services_total_value
    return 0 unless custom_fields&.dig('services').is_a?(Array)

    custom_fields['services'].sum do |service|
      service['value'].to_f
    end
  end

  def pending_tasks_count
    tasks.pending.count
  end

  def overdue_tasks_count
    tasks.overdue.count
  end

  def due_soon_tasks_count
    tasks.due_soon.count
  end

  def completed_tasks_count
    tasks.completed.count
  end

  # rubocop:disable Metrics/AbcSize
  def normalize_services_data!
    return unless custom_fields&.dig('services').is_a?(Array)

    self.custom_fields = custom_fields.dup
    normalized_services = custom_fields['services'].filter_map do |service|
      next unless service.is_a?(Hash) && service['name'].present?

      service_name = service['name'].to_s.strip
      service_value = service['value']&.to_f || 0.0
      service_definition_id = service['service_definition_id']

      normalized_service = {
        'name' => service_name,
        'value' => service_value.round(2).to_s
      }

      if service_definition_id.present?
        normalized_service['service_definition_id'] = service_definition_id.to_s
      else
        catalog_service = find_or_create_catalog_service(service_name, service_value)
        normalized_service['service_definition_id'] = catalog_service.id.to_s if catalog_service
      end

      normalized_service
    end

    custom_fields['services'] = normalized_services

    return unless custom_fields['services'].empty?

    custom_fields.delete('services')
  end
  # rubocop:enable Metrics/AbcSize

  def find_or_create_catalog_service(name, value)
    return nil unless pipeline.present?

    pipeline.pipeline_service_definitions.find_or_create_by!(name: name) do |service_def|
      service_def.default_value = value
      service_def.currency = custom_fields&.dig('currency') || 'BRL'
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  rescue StandardError => e
    Rails.logger.error "Failed to find or create catalog service: #{e.message}"
    nil
  end

  def formatted_services_total(currency = 'BRL')
    return '0,00' if services_total_value.zero?

    case currency
    when 'EUR', 'BRL'
      format('%.2f', services_total_value).tr('.', ',')
    else # USD and other currencies
      format('%.2f', services_total_value)
    end
  end

  def related_to
    conversation || contact
  end

  def lead?
    conversation_id.blank? && contact_id.present?
  end

  def deal?
    conversation_id.present?
  end

  def push_event_data
    {
      id: id,
      pipeline_id: pipeline_id,
      conversation_id: conversation_id,
      contact_id: contact_id,
      is_lead: lead?,
      pipeline_stage: pipeline_stage.push_event_data,
      custom_fields: custom_fields,
      entered_at: entered_at.to_i,
      completed_at: completed_at&.to_i,
      days_in_pipeline: days_in_pipeline,
      services_total: services_total_value
    }
  end

  def webhook_data
    {
      id: id,
      pipeline_id: pipeline_id,
      pipeline_name: pipeline.name,
      conversation_id: conversation_id,
      contact_id: contact_id,
      is_lead: lead?,
      pipeline_stage_id: pipeline_stage_id,
      pipeline_stage_name: pipeline_stage.name,
      custom_fields: custom_fields,
      entered_at: entered_at,
      completed_at: completed_at,
      assigned_by_id: assigned_by_id,
      created_at: created_at,
      updated_at: updated_at,
      conversation: conversation&.webhook_data,
      contact: contact&.webhook_data
    }
  end

  private

  def validate_custom_fields_structure
    return if custom_fields.blank?

    validate_services_structure if custom_fields['services'].present?
    validate_currency_structure if custom_fields['currency'].present?
  end

  def validate_services_structure
    unless custom_fields['services'].is_a?(Array)
      errors.add(:custom_fields, 'Services must be an array')
      return
    end

    custom_fields['services'].each_with_index do |service, index|
      validate_service_object(service, index)
    end
  end

  def validate_service_object(service, index)
    unless service.is_a?(Hash)
      errors.add(:custom_fields, "Service at index #{index} must be an object")
      return
    end

    validate_service_keys(service, index)
    validate_service_types(service, index)
  end

  def validate_service_keys(service, index)
    return if service.key?('name') && service.key?('value')

    errors.add(:custom_fields, "Service at index #{index} must have name and value")
  end

  def validate_service_types(service, index)
    validate_service_name(service, index)
    validate_service_value(service, index)
  end

  def validate_service_name(service, index)
    return unless service['name'].present? && !service['name'].is_a?(String)

    errors.add(:custom_fields, "Service name at index #{index} must be a string")
  end

  def validate_service_value(service, index)
    return unless service['value'].present? && !service['value'].to_s.match?(/^\d*\.?\d+$/)

    errors.add(:custom_fields, "Service value at index #{index} must be a valid number")
  end

  def validate_currency_structure
    valid_currencies = %w[BRL USD EUR]
    return if valid_currencies.include?(custom_fields['currency'])

    errors.add(:custom_fields, 'Currency must be one of: BRL, USD, EUR')
  end

  def must_have_conversation_or_contact
    if conversation_id.blank? && contact_id.blank?
      errors.add(:base, 'Must have either conversation_id or contact_id')
    elsif conversation_id.present? && contact_id.present?
      errors.add(:base, 'Cannot have both conversation_id and contact_id')
    end
  end

  def create_entry_movement
    stage_movements.create!(
      from_stage: nil,
      to_stage: pipeline_stage,
      moved_by: assigned_by,
      movement_type: 'system',
      notes: lead? ? 'Lead added to pipeline' : 'Conversation added to pipeline'
    )
  end

  def create_stage_change_movement
    return unless pipeline_stage_id_previously_changed?

    old_stage_id = pipeline_stage_id_previously_was
    old_stage = PipelineStage.find_by(id: old_stage_id)

    # Cross-pipeline moves are recorded by the caller (e.g.
    # Pipelines::StageAutomationService#move_to_pipeline) with a
    # `cross_pipeline` movement_type that bypasses the same-pipeline
    # validation. Creating a `manual` movement here would otherwise hit
    # `stages_belong_to_same_pipeline` and roll the update back.
    cross_pipeline_change = old_stage && old_stage.pipeline_id != pipeline_stage.pipeline_id

    unless cross_pipeline_change
      stage_movements.create!(
        from_stage: old_stage,
        to_stage: pipeline_stage,
        moved_by: Current.user,
        movement_type: 'manual'
      )
    end

    # Trigger automation event for pipeline stage update
    Rails.configuration.dispatcher.dispatch(
      'pipeline_stage_updated',
      Time.zone.now,
      pipeline_item: self,
      changed_attributes: { 'pipeline_stage_id' => [old_stage_id, pipeline_stage_id] }
    )
  end

  def dispatch_initial_stage_event
    Rails.configuration.dispatcher.dispatch(
      'pipeline_stage_updated',
      Time.zone.now,
      pipeline_item: self,
      changed_attributes: { 'pipeline_stage_id' => [nil, pipeline_stage_id] }
    )
  end

  # EVO-1266: post-commit Wisper broadcast that EvoFlow::PipelineEventsListener
  # consumes to publish the canonical pipeline.stage_changed event to evo-flow
  # for journey trigger matching. Runs after both `after_create_commit` (initial
  # stage assignment — old = nil) and `after_update_commit` (subsequent stage
  # change). Resolves the from/to ids from the dirty-tracking attribute API,
  # which remains valid in the *_commit lifecycle.
  def broadcast_stage_update_to_evo_flow
    old_stage_id, new_stage_id =
      if saved_change_to_pipeline_stage_id?
        saved_change_to_pipeline_stage_id
      else
        [nil, pipeline_stage_id]
      end

    publish(
      :pipeline_stage_updated,
      data: {
        pipeline_item: self,
        changed_attributes: { 'pipeline_stage_id' => [old_stage_id, new_stage_id] }
      }
    )
  end

  # Wisper event publishers (for EvoCampaign integration)
  def publish_pipeline_item_created
    publish(:pipeline_item_created, data: { pipeline_item: self, api_access_token: Current.api_access_token })

    # Also dispatch via event dispatcher for webhooks
    Rails.configuration.dispatcher.dispatch(
      'pipeline_item.created',
      Time.zone.now,
      pipeline_item: self
    )
  end

  def publish_pipeline_item_updated
    return unless saved_changes.any?

    publish(:pipeline_item_updated, data: {
      pipeline_item: self,
      changed_attributes: previous_changes,
      api_access_token: Current.api_access_token
    })

    # Also dispatch via event dispatcher for webhooks
    Rails.configuration.dispatcher.dispatch(
      'pipeline_item.updated',
      Time.zone.now,
      pipeline_item: self,
      changed_attributes: previous_changes
    )
  end

  def publish_pipeline_item_completed
    old_value, new_value = saved_change_to_completed_at || [nil, nil]
    return unless new_value.present? && old_value.blank?

    # Dispatch via event dispatcher for webhooks
    Rails.configuration.dispatcher.dispatch(
      'pipeline_item.completed',
      Time.zone.now,
      pipeline_item: self
    )
  end

  def publish_pipeline_item_deleted
    publish(:pipeline_item_deleted, data: { pipeline_item: self, api_access_token: Current.api_access_token })

    # Also dispatch via event dispatcher for webhooks
    Rails.configuration.dispatcher.dispatch(
      'pipeline_item.cancelled',
      Time.zone.now,
      pipeline_item: self
    )
  end

  public

  # Sum of (quantity * locked_unit_price) across every linked product.
  # Returns a Decimal so callers can format/round as they prefer.
  def total_value
    pipeline_item_products.sum('quantity * locked_unit_price')
  end
end
