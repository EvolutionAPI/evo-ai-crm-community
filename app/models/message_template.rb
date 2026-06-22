# frozen_string_literal: true

# == Schema Information
#
# Table name: message_templates
#
#  id                 :uuid             not null, primary key
#  active             :boolean          default(TRUE)
#  category           :string
#  channel_type       :string
#  components         :jsonb
#  content            :text             not null
#  language           :string           default("pt_BR")
#  media_type         :string
#  media_url          :string
#  metadata           :jsonb
#  name               :string           not null
#  settings           :jsonb
#  template_type      :string
#  variables          :jsonb
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  channel_id         :uuid
#  external_legacy_id :string
#
# Indexes
#
#  idx_message_templates_external_legacy_id  (external_legacy_id) UNIQUE WHERE (external_legacy_id IS NOT NULL)
#  idx_message_templates_global_name         (name) UNIQUE WHERE (channel_id IS NULL)
#  idx_templates_active_by_channel           (channel_type,channel_id,active)
#  idx_templates_by_category                 (category)
#  idx_templates_by_name                     (name)
#  idx_templates_by_type                     (template_type)
#  idx_templates_lookup                      (name,channel_type,channel_id)
#  index_message_templates_on_channel        (channel_type,channel_id)
#

class MessageTemplate < ApplicationRecord
  # Channel is optional so templates can exist as global (channel-less) records.
  # WhatsApp Cloud templates still require a channel (enforced below).
  belongs_to :channel, polymorphic: true, optional: true

  # Non-persisted hint used by the global create path to flag WhatsApp Cloud
  # intent for a channel-less template, so the conditional validation can fire.
  attr_accessor :intended_provider

  # Maps Meta's raw template approval status (stored verbatim in
  # settings['status']) onto a normalized lowercase vocabulary. The raw value is
  # kept in settings['status'] for backward compatibility; `approval_status` is
  # the normalized read view. (EVO-1232)
  META_APPROVAL_STATUS = {
    'APPROVED' => 'approved',
    'REJECTED' => 'rejected',
    'PENDING' => 'pending',
    'PENDING_QUALITY_CHECK' => 'pending',
    'PAUSED' => 'paused',
    'FLAGGED' => 'flagged'
  }.freeze

  validates :name, presence: true
  validates :content, presence: true
  # When channel_type/channel_id are nil this scopes uniqueness to the global
  # (nil, nil) bucket, i.e. global template names are unique.
  validates :name, uniqueness: { scope: [:channel_type, :channel_id] }
  validates :language, presence: true
  validates :media_type, inclusion: { in: %w[image video document audio] }, allow_nil: true
  # Provenance/idempotency key for rows ported into the global flow (EVO-1234).
  validates :external_legacy_id, uniqueness: true, allow_nil: true

  validate :channel_required_for_whatsapp_cloud

  before_save :extract_variables_from_content
  after_initialize :set_defaults

  enum template_type: {
    text: 'text',
    media: 'media',
    interactive: 'interactive',
    location: 'location',
    contact: 'contact',
    product: 'product'
  }, _prefix: true

  enum media_type: {
    image: 'image',
    video: 'video',
    document: 'document',
    audio: 'audio'
  }, _prefix: true

  # Scopes
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :by_channel, ->(channel) { where(channel: channel) }
  scope :by_category, ->(category) { where(category: category) }
  scope :by_type, ->(type) { where(template_type: type) }
  scope :by_language, ->(language) { where(language: language) }
  scope :search_by_name, ->(query) { where('name ILIKE ?', "%#{query}%") }
  scope :most_used, -> { order(Arel.sql('(metadata->>\'usage_count\')::int DESC NULLS LAST')) }
  scope :recently_created, -> { order(created_at: :desc) }

  def render_with_variables(variable_values = {})
    rendered_content = content.dup

    variables.each do |var|
      var_name = var['name']
      var_value = variable_values[var_name] || variable_values[var_name.to_sym]

      if var_value.present?
        rendered_content.gsub!("{{#{var_name}}}", var_value.to_s)
      elsif var['required']
        raise ArgumentError, "Variable '#{var_name}' was not provided"
      end
    end

    rendered_content
  end

  def has_variables?
    variables.present? && variables.any?
  end

  def has_media?
    media_url.present?
  end

  def required_variables
    variables.select { |v| v['required'] == true }
  end

  def optional_variables
    variables.select { |v| v['required'] != true }
  end

  def validate_variables(variable_values)
    errors = []

    required_variables.each do |var|
      var_name = var['name']
      unless variable_values[var_name] || variable_values[var_name.to_sym]
        errors << "Variable '#{var_name}' is required"
      end
    end

    errors
  end

  def preview(variable_values = {})
    {
      name: name,
      content: render_with_variables(variable_values),
      media_url: media_url,
      media_type: media_type,
      components: components,
      variables_used: variable_values
    }
  rescue ArgumentError => e
    {
      error: e.message,
      missing_variables: required_variables.map { |v| v['name'] }
    }
  end

  def clone_for_channel(new_channel, new_name = nil)
    MessageTemplate.create!(
      channel: new_channel,
      name: new_name || "#{name} (copy)",
      content: content,
      language: language,
      category: category,
      template_type: template_type,
      components: components.deep_dup,
      variables: variables.deep_dup,
      media_url: media_url,
      media_type: media_type,
      settings: settings.deep_dup,
      metadata: metadata.deep_dup
    )
  end

  # Meta WhatsApp Cloud template id, persisted by the sync path in
  # metadata['external_id']. Read-only view. (EVO-1232)
  def external_template_id
    metadata.is_a?(Hash) ? metadata['external_id'] : nil
  end

  # Normalized approval status derived from the raw Meta status in
  # settings['status']; 'draft' when the template was never synced. (EVO-1232)
  def approval_status
    raw = settings.is_a?(Hash) ? settings['status'] : nil
    return 'draft' if raw.blank?

    META_APPROVAL_STATUS.fetch(raw.to_s.upcase, raw.to_s.downcase)
  end

  def serialized
    {
      'id' => id,
      'name' => name,
      'content' => content,
      'language' => language,
      'category' => category,
      'template_type' => template_type,
      # 'status' is Meta's raw value (e.g. 'APPROVED'); 'approval_status' is the
      # normalized lowercase view ('approved'). Both intentionally exposed.
      'status' => settings.is_a?(Hash) ? settings['status'] : nil,
      'approval_status' => approval_status,
      'external_template_id' => external_template_id,
      'settings' => settings,
      'components' => components,
      'variables' => variables,
      'media_url' => media_url,
      'media_type' => media_type,
      'active' => active,
      'created_at' => created_at,
      'updated_at' => updated_at
    }
  end

  def self.resolver(options = {})
    ::EmailTemplates::DbResolverService.using self, options
  end

  private

  # WhatsApp Cloud requires a Meta-approved template tied to a WhatsApp Cloud
  # channel (WABA + namespace). A channel-less or wrong-type channel is invalid
  # for a WhatsApp Cloud template. (EVO-1232 strengthens EVO-1231's presence-only
  # rule to also enforce channel type + provider.)
  # A template is "WhatsApp Cloud" when the global create path flags it via
  # intended_provider, or when it is already bound to a WhatsApp Cloud channel.
  def channel_required_for_whatsapp_cloud
    return unless intended_provider == 'whatsapp_cloud' || whatsapp_cloud_channel?(channel)

    # Error key is :channel_id (not :channel) so the JSON payload / frontend bind
    # the validation to the channel_id form field, matching the 6.3 AC. (EVO-1717)
    if channel.blank?
      errors.add(:channel_id, 'is required for WhatsApp Cloud templates')
    elsif !whatsapp_cloud_channel?(channel)
      errors.add(:channel_id, 'must reference a WhatsApp Cloud channel')
    end
  end

  def whatsapp_cloud_channel?(channel)
    channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
  end

  def set_defaults
    self.language ||= 'pt_BR'
    self.template_type ||= 'text'
    self.components ||= {}
    self.variables ||= []
    self.settings ||= {}
    self.metadata ||= {}
  end

  # Extract automated variables automatically from content
  # Format: {{variable_name}}
  def extract_variables_from_content
    return unless content.present?

    extracted_vars = content.scan(/\{\{(\w+)\}\}/).flatten.uniq

    # Included new variables
    existing_var_names = variables.map { |v| v['name'] }
    new_vars = extracted_vars - existing_var_names

    new_vars.each do |var_name|
      self.variables << {
        'name' => var_name,
        'type' => 'text',
        'required' => false
      }
    end

    # Remove variables that are no longer in the content
    self.variables.reject! { |v| !extracted_vars.include?(v['name']) }
  end
end
