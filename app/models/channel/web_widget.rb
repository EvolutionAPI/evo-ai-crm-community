# == Schema Information
#
# Table name: channel_web_widgets
#
#  id                    :uuid             not null, primary key
#  continuity_via_email  :boolean          default(TRUE), not null
#  feature_flags         :integer          default(7), not null
#  hmac_mandatory        :boolean          default(FALSE)
#  hmac_token            :string
#  locale                :string
#  pre_chat_form_enabled :boolean          default(FALSE)
#  pre_chat_form_options :jsonb
#  reply_time            :integer          default("in_a_few_minutes")
#  website_token         :string
#  website_url           :string
#  welcome_tagline       :string
#  welcome_title         :string
#  widget_color          :string           default("#1f93ff")
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
# Indexes
#
#  index_channel_web_widgets_on_hmac_token     (hmac_token) UNIQUE
#  index_channel_web_widgets_on_website_token  (website_token) UNIQUE
#

class Channel::WebWidget < ApplicationRecord
  include Channelable
  include ChannelMessageTemplates
  include FlagShihTzu

  self.table_name = 'channel_web_widgets'
  EDITABLE_ATTRS = [:website_url, :widget_color, :welcome_title, :welcome_tagline, :reply_time, :locale, :pre_chat_form_enabled,
                    :continuity_via_email, :hmac_mandatory,
                    { pre_chat_form_options: [:pre_chat_message, :require_email,
                                              { pre_chat_fields:
                                                [:field_type, :label, :placeholder, :name, :enabled, :type, :enabled, :required,
                                                 :locale, { values: [] }, :regex_pattern, :regex_cue] }] },
                    { selected_feature_flags: [] }].freeze

  before_validation :validate_pre_chat_options
  before_save :normalize_standard_field_types
  validates :website_url, presence: true
  validates :widget_color, presence: true
  validates :locale, inclusion: { in: ApplicationHelper::SUPPORTED_LOCALES }, allow_nil: true

  has_secure_token :website_token
  has_secure_token :hmac_token

  has_flags 1 => :attachments,
            2 => :emoji_picker,
            4 => :end_conversation,
            8 => :use_inbox_avatar_for_bot,
            :column => 'feature_flags',
            :check_for_column => false

  def selected_feature_flags
    flags = []
    flags << :attachments if attachments?
    flags << :emoji_picker if emoji_picker?
    flags << :end_conversation if end_conversation?
    flags << :use_inbox_avatar_for_bot if use_inbox_avatar_for_bot?
    flags
  end

  def selected_feature_flags=(flags_array)
    flags_array = Array(flags_array).map(&:to_sym)
    self.attachments = flags_array.include?(:attachments)
    self.emoji_picker = flags_array.include?(:emoji_picker)
    self.end_conversation = flags_array.include?(:end_conversation)
    self.use_inbox_avatar_for_bot = flags_array.include?(:use_inbox_avatar_for_bot)
  end

  enum reply_time: { in_a_few_minutes: 0, in_a_few_hours: 1, in_a_day: 2 }

  def name
    'Website'
  end

  def web_widget_script
    "
    <script>
      (function(d,t) {
        var BASE_URL=\"#{ENV.fetch('FRONTEND_URL', '')}\";
        var g=d.createElement(t),s=d.getElementsByTagName(t)[0];
        g.src=BASE_URL+\"/packs/js/sdk.js\";
        g.defer = true;
        g.async = true;
        s.parentNode.insertBefore(g,s);
        g.onload=function(){
          window.evolutionSDK.run({
            websiteToken: '#{website_token}',
            baseUrl: BASE_URL
          })
        }
      })(document,\"script\");
    </script>
    "
  end

  def validate_pre_chat_options
    return if pre_chat_form_options.with_indifferent_access['pre_chat_fields'].present?

    self.pre_chat_form_options = {
      pre_chat_message: 'Share your queries or comments here.',
      pre_chat_fields: [
        {
          'field_type': 'standard', 'label': 'Email Id', 'name': 'emailAddress', 'type': 'email', 'required': true, 'enabled': false, 'placeholder': 'Email Id'
        },
        {
          'field_type': 'standard', 'label': 'Full name', 'name': 'fullName', 'type': 'text', 'required': false, 'enabled': false, 'placeholder': 'Full name'
        },
        {
          'field_type': 'standard', 'label': 'Phone number', 'name': 'phoneNumber', 'type': 'text', 'required': false, 'enabled': false, 'placeholder': 'Phone number'
        }
      ]
    }
  end

  def create_contact_inbox(additional_attributes = {})
    ::ContactInboxWithContactBuilder.new({
                                           inbox: inbox,
                                           contact_attributes: { additional_attributes: additional_attributes }
                                         }).perform
  end

  private

  STANDARD_FIELD_NAMES = %w[emailAddress fullName phoneNumber].freeze

  def normalize_standard_field_types
    return unless pre_chat_form_options.present?

    options = pre_chat_form_options.with_indifferent_access
    fields = options['pre_chat_fields']
    return unless fields.is_a?(Array)

    fields.each do |field|
      next unless field.is_a?(Hash)
      field['field_type'] = 'standard' if STANDARD_FIELD_NAMES.include?(field['name'])
    end

    self.pre_chat_form_options = options
  end
end
