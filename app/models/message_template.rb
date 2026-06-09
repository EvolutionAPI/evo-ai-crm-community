# frozen_string_literal: true

# == Schema Information
#
# Table name: message_templates
#
#  id            :uuid             not null, primary key
#  active        :boolean          default(TRUE)
#  category      :string
#  channel_type  :string
#  components    :jsonb
#  content       :text             not null
#  language      :string           default("pt_BR")
#  media_type    :string
#  media_url     :string
#  metadata      :jsonb
#  name          :string           not null
#  settings      :jsonb
#  template_type :string
#  variables     :jsonb
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  channel_id    :uuid
#
# Indexes
#
#  idx_message_templates_global_name   (name) UNIQUE WHERE (channel_id IS NULL)
#  idx_templates_active_by_channel     (channel_type,channel_id,active)
#  idx_templates_by_category           (category)
#  idx_templates_by_name               (name)
#  idx_templates_by_type               (template_type)
#  idx_templates_lookup                (name,channel_type,channel_id)
#  index_message_templates_on_channel  (channel_type,channel_id)
#

class MessageTemplate < ApplicationRecord
  # Channel is optional so templates can exist as global (channel-less) records.
  # WhatsApp Cloud templates still require a channel (enforced below).
  belongs_to :channel, polymorphic: true, optional: true

  # Non-persisted hint used by the global create path to flag WhatsApp Cloud
  # intent for a channel-less template, so the conditional validation can fire.
  attr_accessor :intended_provider

  validates :name, presence: true
  validates :content, presence: true
  # When channel_type/channel_id are nil this scopes uniqueness to the global
  # (nil, nil) bucket, i.e. global template names are unique.
  validates :name, uniqueness: { scope: [:channel_type, :channel_id] }
  validates :language, presence: true
  validates :media_type, inclusion: { in: %w[image video document audio] }, allow_nil: true

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

  def serialized
    {
      'id' => id,
      'name' => name,
      'content' => content,
      'language' => language,
      'category' => category,
      'template_type' => template_type,
      'status' => settings.is_a?(Hash) ? settings['status'] : nil,
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

  # WhatsApp Cloud requires a Meta-approved template tied to its channel, so a
  # channel-less template flagged as WhatsApp Cloud is invalid.
  def channel_required_for_whatsapp_cloud
    return if channel.present?

    errors.add(:channel, 'is required for WhatsApp Cloud templates') if intended_provider == 'whatsapp_cloud'
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
