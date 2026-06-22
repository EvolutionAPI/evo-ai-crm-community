# == Schema Information
#
# Table name: contacts
#
#  id                       :uuid             not null, primary key
#  additional_attributes    :jsonb
#  blocked                  :boolean          default(FALSE), not null
#  contact_type             :integer          default("visitor")
#  country_code             :string           default("")
#  custom_attributes        :jsonb
#  email                    :string
#  email_suppressed         :boolean          default(FALSE), not null
#  email_suppression_reason :string
#  identifier               :string
#  industry                 :string
#  last_activity_at         :datetime
#  last_name                :string           default("")
#  location                 :string           default("")
#  middle_name              :string           default("")
#  name                     :string           default("")
#  phone_number             :string
#  type                     :enum             default("person"), not null
#  website                  :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  tax_id                   :string(14)
#
# Indexes
#
#  idx_contacts_name_type_resolved                       (name,type,id) WHERE (((email)::text <> ''::text) OR ((phone_number)::text <> ''::text) OR ((identifier)::text <> ''::text))
#  idx_contacts_with_identity                            (id) WHERE (((email)::text <> ''::text) OR ((phone_number)::text <> ''::text) OR ((identifier)::text <> ''::text))
#  index_contacts_on_blocked                             (blocked)
#  index_contacts_on_last_activity_at                    (last_activity_at)
#  index_contacts_on_name_email_phone_number_identifier  (name,email,phone_number,identifier) USING gin
#  index_contacts_on_phone_number                        (phone_number)
#  index_contacts_on_tax_id                              (tax_id) UNIQUE WHERE (tax_id IS NOT NULL)
#  index_contacts_on_type                                (type)
#  uniq_email_per_account_contact                        (email) UNIQUE
#  uniq_identifier_per_account_contact                   (identifier) UNIQUE
#
class Contact < ApplicationRecord
  include Avatarable
  include AvailabilityStatusable
  include Labelable
  include LlmFormattable
  include Wisper::Publisher

  self.inheritance_column = :_type_disabled
  attr_accessor :skip_default_pipeline_assignment

  TYPES = %w[person company group].freeze

  validates :type, presence: true, inclusion: { in: TYPES }
  validates :email, allow_blank: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP, message: I18n.t('errors.contacts.email.invalid') }
  validates :identifier, allow_blank: true, uniqueness: true
  validates :phone_number,
            allow_blank: true, uniqueness: true,
            format: { with: /\+[1-9]\d{1,14}\z/, message: I18n.t('errors.contacts.phone_number.invalid') }
  validates :tax_id, allow_blank: true, uniqueness: true, length: { maximum: 14 }
  validates :website, allow_blank: true, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]), message: 'must be a valid URL' }
  has_many :conversations, dependent: :destroy_async
  has_many :contact_inboxes, dependent: :destroy_async
  has_many :csat_survey_responses, dependent: :destroy_async
  has_many :inboxes, through: :contact_inboxes
  has_many :messages, as: :sender, dependent: :destroy_async
  has_many :notes, dependent: :destroy_async
  has_many :pipeline_items, dependent: :destroy_async

  has_many :contact_companies, dependent: :destroy
  has_many :companies, through: :contact_companies, source: :company

  has_many :company_contacts, class_name: 'ContactCompany', foreign_key: 'company_id', dependent: :nullify, inverse_of: :company
  has_many :comp_contacts, through: :company_contacts, source: :contact
  after_initialize :set_default_location
  before_validation :prepare_contact_attributes, :ensure_location_present
  before_save :ensure_location_present
  # after_create_commit :dispatch_create_event # Disabled - using Wisper events instead
  after_create_commit :ip_lookup, :publish_contact_created, :assign_to_default_pipeline, :trigger_contact_created_automation
  # after_update_commit :dispatch_update_event # Disabled - using Wisper events instead
  after_update_commit :publish_contact_updated, :publish_custom_attribute_changes, :publish_label_changes,
                      :trigger_contact_updated_automation
  before_save :sync_contact_attributes
  before_destroy :ensure_pipeline_items_cleanup, :publish_contact_deleted
  after_destroy_commit :dispatch_destroy_event

  enum contact_type: { visitor: 0, lead: 1, customer: 2 }

  scope :persons, -> { where(type: 'person') }
  scope :companies, -> { where(type: 'company') }
  scope :groups, -> { where(type: 'group') }
  scope :non_groups, -> { where.not(type: 'group') }
  scope :for_company, ->(company_id) { joins(:contact_companies).where(contact_companies: { company_id: company_id }) }

  scope :order_on_last_activity_at, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order("\"contacts\".\"last_activity_at\" #{direction}
          NULLS LAST")
      )
    )
  }
  scope :order_on_created_at, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order("\"contacts\".\"created_at\" #{direction}
          NULLS LAST")
      )
    )
  }
  scope :order_on_company_name, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order(
          "\"contacts\".\"additional_attributes\"->>'company_name' #{direction}
          NULLS LAST"
        )
      )
    )
  }
  scope :order_on_city, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order(
          "\"contacts\".\"additional_attributes\"->>'city' #{direction}
          NULLS LAST"
        )
      )
    )
  }
  scope :order_on_country_name, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order(
          "\"contacts\".\"additional_attributes\"->>'country' #{direction}
          NULLS LAST"
        )
      )
    )
  }

  scope :order_on_name, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order(
          "CASE
           WHEN \"contacts\".\"name\" ~~* '^+\d*' THEN 'z'
           WHEN \"contacts\".\"name\"  ~~*  '^\b*' THEN 'z'
           ELSE LOWER(\"contacts\".\"name\")
           END #{direction}"
        )
      )
    )
  }

  # Find contacts that:
  # 1. Have no identification (email, phone_number, and identifier are NULL or empty string)
  # 2. Have no conversations
  # 3. Are older than the specified time period
  scope :stale_without_conversations, lambda { |time_period|
    where('contacts.email IS NULL OR contacts.email = ?', '')
      .where('contacts.phone_number IS NULL OR contacts.phone_number = ?', '')
      .where('contacts.identifier IS NULL OR contacts.identifier = ?', '')
      .where('contacts.created_at < ?', time_period)
      .where.missing(:conversations)
  }

  def get_source_id(inbox_id)
    contact_inboxes.find_by!(inbox_id: inbox_id).source_id
  end

  def push_event_data
    # EVO-1551 round 3: every caller of `push_event_data` is a websocket
    # broadcast (listeners, conversation event presenter, message sender),
    # and those broadcasts have **mixed audience** — admins + agents subscribed
    # to the same topic. The trigger may be an admin (Current.user) but the
    # payload reaches agents on `account_token`/inbox-member tokens, so we
    # must mask based on the account flag alone, ignoring `Current.user`.
    # `should_mask?` is reserved for serializers (per-request HTTP responses).
    masked = ContactPiiMasker.account_flag_enabled?
    {
      additional_attributes: additional_attributes,
      custom_attributes: custom_attributes,
      email: masked ? ContactPiiMasker.mask_email(email) : email,
      id: id,
      identifier: masked ? ContactPiiMasker.mask_identifier(identifier) : identifier,
      name: masked ? ContactPiiMasker.mask_phone_like_name(name) : name,
      phone_number: masked ? ContactPiiMasker.mask_phone(phone_number) : phone_number,
      thumbnail: avatar_url,
      blocked: blocked,
      type: 'contact'
    }
  end

  def webhook_data
    {
      additional_attributes: additional_attributes,
      avatar: avatar_url,
      custom_attributes: custom_attributes,
      email: email,
      id: id,
      identifier: identifier,
      name: name,
      phone_number: phone_number,
      thumbnail: avatar_url,
      blocked: blocked
    }
  end

  def self.resolved_contacts
    # Include contacts that have email, phone_number, or identifier
    # Also include contacts that have contact_inboxes (have at least one conversation)
    # This uses LEFT JOIN for better performance
    joins(
      "LEFT JOIN contact_inboxes ON contact_inboxes.contact_id = contacts.id"
    ).where(
      "contacts.email <> '' OR contacts.phone_number <> '' OR contacts.identifier <> '' OR contact_inboxes.id IS NOT NULL"
    )
  end

  def discard_invalid_attrs
    phone_number_format
    email_format
  end

  def self.from_email(email)
    find_by(email: email&.downcase)
  end

  def company?
    type == 'company'
  end

  def person?
    type == 'person'
  end

  def group?
    type == 'group'
  end

  private

  def ip_lookup
    ContactIpLookupJob.perform_later(self)
  end

  def phone_number_format
    return if phone_number.blank?

    self.phone_number = phone_number_was unless phone_number.match?(/\+[1-9]\d{1,14}\z/)
  end

  def email_format
    return if email.blank?

    # Use a basic email regex pattern instead of Devise.email_regexp
    email_regex = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i
    self.email = email_was unless email.match(email_regex)
  end

  def prepare_contact_attributes
    prepare_email_attribute
    prepare_phone_number_attribute
    prepare_jsonb_attributes
  end

  # Normalize the phone number to the canonical form WhatsApp resolves to, so that
  # every write path (leads API, widget, import, inbound WhatsApp) converges on one
  # string and stops creating duplicate contacts. See Whatsapp::PhoneNumberNormalizer
  # (a faithful port of Evolution API's createJid). The E.164 format validation below
  # remains the final guard.
  def prepare_phone_number_attribute
    return if phone_number.blank?

    # Only normalize when the value is actually being set or changed in this save.
    # Re-normalizing an untouched persisted record would lazily rewrite legacy
    # numbers (e.g. older inbound 13-digit form) and could collide with the
    # uniqueness validation against a pre-existing twin — turning a harmless
    # legacy duplicate into a hard save error. New records and real edits still
    # get normalized; cleaning up legacy twins is a separate dedupe job.
    return unless phone_number_changed?

    digits = Whatsapp::PhoneNumberNormalizer.call(phone_number)
    return if digits.blank?

    self.phone_number = "+#{digits}"
  end

  def prepare_email_attribute
    # So that the db unique constraint won't throw error when email is ''
    self.email = email.present? ? email.downcase : nil
  end

  def prepare_jsonb_attributes
    self.additional_attributes = {} if additional_attributes.blank?
    self.custom_attributes = {} if custom_attributes.blank?
  end

  def set_default_location
    self.location ||= ''
    self.country_code ||= ''
    self.type ||= 'person' # Default type to 'person' if not provided
  end

  def ensure_location_present
    # Garantir que location e country_code nunca sejam nil
    self.location = '' if location.nil? || location.blank?
    self.country_code = '' if country_code.nil? || country_code.blank?
  end

  def sync_contact_attributes
    ::Contacts::SyncAttributes.new(self).perform
  end

  def dispatch_create_event
    Rails.configuration.dispatcher.dispatch(CONTACT_CREATED, Time.zone.now, contact: self, api_access_token: Current.api_access_token)
  end

  def dispatch_update_event
    Rails.configuration.dispatcher.dispatch(CONTACT_UPDATED, Time.zone.now, contact: self, changed_attributes: previous_changes,
                                                                            api_access_token: Current.api_access_token)
  end

  def dispatch_destroy_event
    Rails.configuration.dispatcher.dispatch(CONTACT_DELETED, Time.zone.now, contact: self)
  end

  # Feeds contact events to automation rules ONLY (see AutomationContactEventJob).
  # The broad dispatch_*_event path above stays disabled; this is the narrow
  # bridge that keeps contact-triggered automations working.
  def trigger_contact_created_automation
    enqueue_contact_automation('contact_created')
  end

  def trigger_contact_updated_automation
    enqueue_contact_automation('contact_updated')
  end

  # Loop guard: when the contact change was itself made by a running automation
  # (Current.executed_by is the rule), do not enqueue another automation pass.
  #
  # Rule guard: skip enqueueing entirely when no active rule listens for this
  # event. Without it, every contact write (including bulk import/sync) spawns an
  # empty background job that loads the contact only to find nothing to run.
  def enqueue_contact_automation(event_name)
    return if Current.executed_by.is_a?(AutomationRule)
    return unless AutomationRule.exists?(event_name: event_name, active: true)

    AutomationContactEventJob.perform_later(event_name, id, previous_changes.as_json)
  end

  # Wisper event publishers
  def publish_contact_created
    publish(:contact_created, data: { contact: self, api_access_token: Current.api_access_token })
  end

  def publish_contact_updated
    return unless saved_changes.any?

    publish(:contact_updated, data: {
              contact: self,
              changed_attributes: previous_changes,
              api_access_token: Current.api_access_token
            })
  end

  # Publish custom attribute changes
  def publish_custom_attribute_changed(attribute_name, new_value, old_value, change_type)
    publish(:contact_custom_attribute_changed, data: {
              contact: self,
              attribute_name: attribute_name,
              attribute_value: new_value,
              old_value: old_value,
              change_type: change_type,
              occurred_at: Time.zone.now,
              api_access_token: Current.api_access_token
            })
  end

  # H2: diff `custom_attributes` jsonb on update and emit one Wisper event
  # per changed key so EvoFlow::ContactEventsListener#contact_custom_attribute_changed
  # actually fires in production (the publisher was previously orphaned).
  def publish_custom_attribute_changes
    return unless saved_change_to_custom_attributes?

    before, after = saved_change_to_custom_attributes
    before ||= {}
    after ||= {}
    (before.keys | after.keys).each do |attribute_name|
      old_value = before[attribute_name]
      new_value = after[attribute_name]
      next if old_value == new_value

      publish_custom_attribute_changed(attribute_name, new_value, old_value, custom_attr_change_type(old_value, new_value))
    end
  end

  def custom_attr_change_type(old_value, new_value)
    return 'added' if old_value.nil?
    return 'removed' if new_value.nil?

    'updated'
  end

  # F-2: diff `label_list` on update and emit one Wisper event per added/removed
  # label so EvoFlow listeners observe label changes via the setter path —
  # `update(label_list: ...)`, `Labelable#update_labels/#add_labels`,
  # `AutomationRules::FlowExecutionService#add_label/#remove_label`, and
  # `Labels::UpdateService` rename. These all dirty-track `label_list` and
  # hit `saved_change_to_label_list?`.
  #
  # NOTE: `contact.label_list.add(...)/.remove(...) + contact.save!` mutates
  # the cached TagList in place and does NOT dirty-track the attribute — this
  # callback returns early on that path. Callers that need event emission
  # must use the setter (route via `update!(label_list: ...)`).
  def publish_label_changes
    return unless saved_change_to_label_list?

    # `previous_changes` uses string keys for AR attributes but `label_list`
    # is an acts-as-taggable-on virtual attribute exposed via dirty tracking
    # under `saved_change_to_label_list` — use that directly.
    before, after = saved_change_to_label_list
    before = Array(before)
    after = Array(after)

    (after - before).each { |label_name| publish_label_added(label_name) }
    (before - after).each { |label_name| publish_label_removed(label_name) }
  end

  # Publish label changes
  def publish_label_added(label_name)
    publish(:contact_label_added, data: {
              contact: self,
              label_name: label_name,
              label_id: ::Label.find_by(title: label_name.to_s)&.id,
              occurred_at: Time.zone.now,
              api_access_token: Current.api_access_token
            })
  end

  def publish_label_removed(label_name)
    publish(:contact_label_removed, data: {
              contact: self,
              label_name: label_name,
              label_id: ::Label.find_by(title: label_name.to_s)&.id,
              occurred_at: Time.zone.now,
              api_access_token: Current.api_access_token
            })
  end

  def publish_contact_deleted
    publish(:contact_deleted, data: {
              contact: self,
              reason: 'user_action',
              api_access_token: Current.api_access_token
            })
  end

  def add_company(company)
    return false unless person? && company.company?
    return false if companies.include?(company)

    companies << company
    Rails.configuration.dispatcher.dispatch(
      'contact_company_linked',
      Time.zone.now,
      contact: self,
      company: company
    )
    true
  rescue ActiveRecord::RecordInvalid
    false
  end

  def remove_company(company)
    return false unless companies.include?(company)

    companies.delete(company)
    Rails.configuration.dispatcher.dispatch(
      'contact_company_unlinked',
      Time.zone.now,
      contact: self,
      company: company
    )
    true
  end

  def comp_contacts_count
    return 0 unless company?

    comp_contacts.count
  end

  validate :company_cannot_have_companies, if: :company?

  def company_cannot_have_companies
    return unless companies.any?

    errors.add(:base, 'Companies cannot be linked to other companies')
  end

  def assign_to_default_pipeline
    return if skip_default_pipeline_assignment
    return if group?

    default_pipeline = Pipeline.default.first
    return unless default_pipeline

    # Don't auto-assign to the default pipeline if the contact already belongs to
    # an active journey in ANY pipeline — otherwise the same contact ends up in two
    # pipelines at once (e.g. a custom "Jornada Pós-Compra" item plus a default one).
    return if pipeline_items.active.exists?

    default_pipeline.add_contact(self, nil, nil)
  rescue StandardError => e
    Rails.logger.error "Failed to add contact #{id} to default pipeline: #{e.message}"
  end

  def ensure_pipeline_items_cleanup
    return if pipeline_items.empty? && conversations.none? { |c| c.pipeline_items.exists? }

    if pipeline_items.exists? || conversations.any? { |c| c.pipeline_items.exists? }
      Rails.logger.warn "Contact #{id} has pipeline_items that should be cleaned up synchronously before destroy. Controller should handle this via cleanup_contact_pipeline_items."
    end
  end
end
