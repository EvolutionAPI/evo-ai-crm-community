class ApplicationMailer < ActionMailer::Base
  include ActionView::Helpers::SanitizeHelper

  DEFAULT_SENDER_EMAIL = 'accounts@evoai.app'.freeze

  default from: proc { ApplicationMailer.get_mailer_sender_email }
  around_action :switch_locale
  before_action :load_dynamic_mail_settings
  after_action :apply_dynamic_delivery_settings
  layout 'mailer/base'
  # Fetch template from Database if available
  # Order: Account Specific > Installation Specific > Fallback to file
  prepend_view_path ::MessageTemplate.resolver
  append_view_path Rails.root.join('app/views/mailers')
  helper :frontend_urls
  helper do
    def global_config
      @global_config ||= GlobalConfig.get('BRAND_NAME', 'BRAND_URL')
    end
  end

  rescue_from(*ExceptionList::SMTP_EXCEPTIONS, with: :handle_smtp_exceptions)

  def smtp_config_set_or_development?
    return true if Rails.env.development?
    return true if ENV.fetch('SMTP_ADDRESS', nil).present?

    if defined?(GlobalConfigService)
      mailer_type = GlobalConfigService.load('MAILER_TYPE', nil)
      return true if mailer_type.present?

      db_address = GlobalConfigService.load('SMTP_ADDRESS', nil)
      return true if db_address.present?
    end

    false
  end

  private

  def load_dynamic_mail_settings
    return unless defined?(GlobalConfigService)

    mailer_type = GlobalConfigService.load('MAILER_TYPE', 'smtp')

    case mailer_type
    when 'bms'
      if GlobalConfigService.load('BMS_API_SECRET', nil).present?
        @dynamic_delivery_method = :bms
        @dynamic_delivery_options = {}
      end
    when 'resend'
      resend_api_key = GlobalConfigService.load('RESEND_API_SECRET', ENV.fetch('RESEND_API_KEY', nil))
      if resend_api_key.present?
        @dynamic_resend_api_key = resend_api_key
        @dynamic_delivery_method = :resend
        @dynamic_delivery_options = {}
      end
    else
      load_dynamic_smtp_settings
    end
  rescue => e
    Rails.logger.warn "Failed to load dynamic mail settings: #{e.message}"
  end

  def load_dynamic_smtp_settings
    address = GlobalConfigService.load('SMTP_ADDRESS', ENV.fetch('SMTP_ADDRESS', nil))
    return unless address.present?

    # Merge onto boot-time settings to preserve SSL/TLS/timeout from ENV
    smtp = (self.class.smtp_settings || {}).dup
    smtp[:address] = address
    smtp[:port] = GlobalConfigService.load('SMTP_PORT', ENV.fetch('SMTP_PORT', 587)).to_i
    smtp[:user_name] = GlobalConfigService.load('SMTP_USERNAME', ENV.fetch('SMTP_USERNAME', nil))
    smtp[:password] = GlobalConfigService.load('SMTP_PASSWORD_SECRET', ENV.fetch('SMTP_PASSWORD', nil))
    smtp[:enable_starttls_auto] = ActiveModel::Type::Boolean.new.cast(
      GlobalConfigService.load('SMTP_ENABLE_STARTTLS_AUTO', ENV.fetch('SMTP_ENABLE_STARTTLS_AUTO', true))
    )

    auth = GlobalConfigService.load('SMTP_AUTHENTICATION', ENV.fetch('SMTP_AUTHENTICATION', nil))
    smtp[:authentication] = auth.to_sym if auth.present?

    domain = GlobalConfigService.load('SMTP_DOMAIN', ENV.fetch('SMTP_DOMAIN', nil))
    smtp[:domain] = domain if domain.present?

    verify_mode = GlobalConfigService.load('SMTP_OPENSSL_VERIFY_MODE', ENV.fetch('SMTP_OPENSSL_VERIFY_MODE', nil))
    smtp[:openssl_verify_mode] = verify_mode if verify_mode.present?

    @dynamic_delivery_method = :smtp
    @dynamic_delivery_options = smtp
  end

  def apply_dynamic_delivery_settings
    return unless @dynamic_delivery_method

    options = @dynamic_delivery_options || {}

    if @dynamic_delivery_method == :resend && @dynamic_resend_api_key
      options = options.merge(api_key: @dynamic_resend_api_key)
    end

    delivery_class = self.class.delivery_methods[@dynamic_delivery_method]
    if delivery_class.nil?
      Rails.logger.warn "ApplicationMailer: unregistered delivery method '#{@dynamic_delivery_method}' — passing symbol directly, mail gem may reject it"
      delivery_class = @dynamic_delivery_method
    end
    message.delivery_method(delivery_class, options)
  end

  def handle_smtp_exceptions(message)
    Rails.logger.warn 'Failed to send Email'
    Rails.logger.error "Exception: #{message}"
  end

  def send_mail_with_liquid(*args)
    Rails.logger.info "📤 EMAIL: Preparing to send email to #{args[0][:to]} with subject '#{args[0][:subject]}'"
    Rails.logger.info "📤 EMAIL: Using delivery method: #{@dynamic_delivery_method || ActionMailer::Base.delivery_method}"

    mail_obj = mail(*args) do |format|
      # explored sending a multipart email containing both text type and html
      # parsing the html with nokogiri will remove the links as well
      # might also remove tags like b,li etc. so lets rethink about this later
      # format.text { Nokogiri::HTML(render(layout: false)).text }
      format.html { render }
    end

    Rails.logger.info "📤 EMAIL: Mail object created, ready for delivery"
    mail_obj
  end

  def liquid_droppables
    # Merge additional objects into this in your mailer
    # liquid template handler converts these objects into drop objects
    {
      user: @agent,
      conversation: @conversation,
      inbox: @conversation&.inbox
    }
  end

  def liquid_locals
    # expose variables you want to be exposed in liquid
    locals = {
      global_config: GlobalConfig.get('BRAND_NAME', 'BRAND_URL'),
      action_url: @action_url
    }

    locals.merge({ attachment_url: @attachment_url }) if @attachment_url
    locals.merge({ failed_contacts: @failed_contacts, imported_contacts: @imported_contacts })
    locals
  end

  def self.get_mailer_sender_email
    begin
      # Try GlobalConfig first, then fallback to ENV
      sender_email = GlobalConfigService.load('MAILER_SENDER_EMAIL', nil) if defined?(GlobalConfigService)
      sender_email.presence || ENV.fetch('MAILER_SENDER_EMAIL', DEFAULT_SENDER_EMAIL)
    rescue => e
      Rails.logger.warn "Failed to load MAILER_SENDER_EMAIL from GlobalConfig: #{e.message}" if defined?(Rails.logger)
      ENV.fetch('MAILER_SENDER_EMAIL', DEFAULT_SENDER_EMAIL)
    end
  end

  def switch_locale(&)
    locale = I18n.default_locale
    # ensure locale won't bleed into other requests
    # https://guides.rubyonrails.org/i18n.html#managing-the-locale-across-requests
    I18n.with_locale(locale, &)
  end
end
