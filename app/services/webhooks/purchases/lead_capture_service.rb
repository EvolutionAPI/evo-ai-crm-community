# frozen_string_literal: true

# Turns an approved purchase (canonical lead shape, see PurchaseAdapters::Base)
# into a contact + a pipeline card on the pipeline's entry stage. Modeled on
# Public::Leads::CreationService, minus its known pitfalls:
#   * new contacts set `skip_default_pipeline_assignment` — otherwise the
#     after_create_commit callback races this service and the contact lands
#     with a second card on the default pipeline;
#   * contact matching is email -> normalized phone, writes are ADDITIVE on
#     existing contacts (a webhook must not clobber CRM-owned data);
#   * phone-conflict errors never leak another contact's data.
#
# Idempotency: the (provider, purchase_id) pair lives in the card's
# custom_fields['purchase'] and is enforced by a partial UNIQUE expression
# index — a concurrent redelivery falls into RecordNotUnique and is answered
# as :duplicate with the existing ids.
module Webhooks
  module Purchases
    class LeadCaptureService
      Result = Struct.new(:status, :contact, :pipeline_item, :details, keyword_init: true)

      LEAD_SOURCE = 'purchase_webhook'

      def initialize(provider:, lead:, pipeline_id: nil, product_override: nil)
        @provider = provider.to_s
        @lead = lead
        @pipeline_id = pipeline_id
        @product_override = product_override
      end

      def perform
        return Result.new(status: :ignored, details: { event: @lead[:event] }) unless @lead[:approved]

        if (existing = find_existing_item)
          return Result.new(status: :duplicate, contact: existing.contact, pipeline_item: existing)
        end

        pipeline_error = resolve_pipeline!
        return pipeline_error if pipeline_error

        capture!
      rescue ActiveRecord::RecordNotUnique
        existing = find_existing_item
        Result.new(status: :duplicate, contact: existing&.contact, pipeline_item: existing)
      end

      private

      # No wrapping transaction on purpose: a committed contact with a failed
      # card is the GOOD failure shape — the platform's redelivery finds the
      # contact and only retries the card. Each create! is atomic on its own.
      def capture!
        contact_result = find_or_create_contact
        return contact_result if contact_result.is_a?(Result)

        @contact = contact_result
        item_result = create_pipeline_item
        return item_result if item_result.is_a?(Result)

        Result.new(status: :created, contact: @contact, pipeline_item: item_result)
      end

      def find_existing_item
        PipelineItem
          .where("custom_fields -> 'purchase' ->> 'provider' = ?", @provider)
          .find_by("custom_fields -> 'purchase' ->> 'purchase_id' = ?", @lead[:purchase_id])
      end

      def resolve_pipeline!
        @pipeline = @pipeline_id.present? ? Pipeline.find_by(id: @pipeline_id) : Pipeline.default.first
        return Result.new(status: :pipeline_not_found, details: { pipeline_id: @pipeline_id }) unless @pipeline

        @entry_stage = @pipeline.pipeline_stages.order(:position, :id).first
        return Result.new(status: :pipeline_not_found, details: { reason: 'pipeline has no stages' }) unless @entry_stage

        nil
      end

      def find_or_create_contact
        email = @lead[:email].to_s.downcase.presence
        phone = normalized_phone

        contact = (email && Contact.from_email(email)) || (phone && Contact.find_by(phone_number: phone))
        contact ? update_existing_contact(contact, phone) : create_contact(email, phone)
      rescue ActiveRecord::RecordInvalid => e
        Result.new(status: :contact_error, details: { errors: e.record.errors.full_messages })
      end

      def create_contact(email, phone)
        contact = Contact.new(
          name: @lead[:name].presence || email&.split('@')&.first || 'Comprador',
          email: email,
          phone_number: phone,
          additional_attributes: {},
          custom_attributes: {}
        )
        contact.skip_default_pipeline_assignment = true
        contact.save!
        contact
      end

      # Additive only: fill blanks, never overwrite. A phone that already
      # belongs to ANOTHER contact is skipped silently on the wire (logged) —
      # naming the owner would let a signed-but-curious platform enumerate
      # contacts.
      def update_existing_contact(contact, phone)
        updates = {}
        updates[:name] = @lead[:name] if contact.name.blank? && @lead[:name].present?
        if contact.phone_number.blank? && phone.present?
          if Contact.where.not(id: contact.id).exists?(phone_number: phone)
            Rails.logger.warn("Purchase webhook: phone on purchase #{@lead[:purchase_id]} belongs to another contact — skipped")
          else
            updates[:phone_number] = phone
          end
        end
        contact.update!(updates) if updates.any?
        contact
      end

      def normalized_phone
        return nil if @lead[:phone_number].blank?

        phone = Whatsapp::PhoneNumberNormalizer.to_e164(@lead[:phone_number])
        phone.presence&.match?(/\A\+[1-9]\d{1,14}\z/) ? phone : nil
      end

      def create_pipeline_item
        @pipeline.pipeline_items.create!(
          contact: @contact,
          conversation: nil,
          pipeline_stage: @entry_stage,
          entered_at: Time.current,
          custom_fields: card_custom_fields
        )
      rescue ActiveRecord::RecordInvalid => e
        active = @pipeline.pipeline_items.active.find_by(contact_id: @contact.id)
        return Result.new(status: :already_in_pipeline, contact: @contact, pipeline_item: active) if active

        Result.new(status: :pipeline_item_error, details: { errors: e.record.errors.full_messages })
      end

      def card_custom_fields
        fields = {
          'lead_source' => LEAD_SOURCE,
          'purchase' => {
            'provider' => @provider,
            'purchase_id' => @lead[:purchase_id],
            'event' => @lead[:event],
            'product' => @product_override.presence || @lead[:product],
            'amount' => @lead[:amount],
            'currency' => @lead[:currency]
          }.compact
        }
        fields['value'] = @lead[:amount] if @lead[:amount].present?
        fields
      end
    end
  end
end
