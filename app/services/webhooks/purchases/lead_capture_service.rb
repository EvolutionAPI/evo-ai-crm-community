# frozen_string_literal: true

# Turns an approved purchase (canonical lead shape, see PurchaseAdapters::Base)
# into a contact + a pipeline card on the entry stage. Idempotent by the partial
# UNIQUE index on the card's custom_fields['purchase'] (pipeline, provider,
# purchase_id) — redelivery and concurrent retry both answer :duplicate.
module Webhooks
  module Purchases
    class LeadCaptureService
      include Wisper::Publisher

      Result = Struct.new(:status, :contact, :pipeline_item, :details, keyword_init: true)

      LEAD_SOURCE = 'purchase_webhook'
      # E.164 with a plausible length: without the floor, a truncated "123"
      # normalizes to "+123" and is persisted as a contact nobody can reach.
      E164 = /\A\+[1-9]\d{9,14}\z/

      def initialize(provider:, lead:, pipeline_id: nil, product_override: nil)
        @provider = provider.to_s
        @lead = lead
        @pipeline_id = pipeline_id
        @product_override = product_override
      end

      def perform
        return Result.new(status: :ignored, details: { event: @lead[:event] }) unless @lead[:approved]

        pipeline_error = resolve_pipeline!
        return pipeline_error if pipeline_error

        if (existing = find_existing_item)
          return Result.new(status: :duplicate, contact: existing.contact, pipeline_item: existing)
        end

        announce(capture!)
      end

      private

      # CRM-316: a sale the CRM did not already know becomes purchase.approved on
      # evo-flow. Fires after the writes committed; a listener failure never
      # fails the webhook (EvoFlow listeners rescue internally).
      def announce(result)
        return result unless emit_purchase_event?(result)

        broadcast(
          :purchase_approved,
          contact: result.contact, pipeline_item: result.pipeline_item,
          provider: @provider, purchase: card_custom_fields['purchase'],
          outcome: result.status, new_contact: @contact_created == true
        )
        result
      end

      # The open card's `purchases` history is the idempotency record of a second
      # sale, so a delivery that appended nothing emits nothing — evo-flow has no
      # consumer-side dedup to fall back on.
      def emit_purchase_event?(result)
        case result.status
        when :created then true
        when :already_in_pipeline then @extra_purchase_recorded
        else false
        end
      end

      # No wrapping transaction on purpose: a committed contact with a failed
      # card is the GOOD failure shape — the redelivery finds the contact and
      # only retries the card.
      def capture!
        contact_result = find_or_create_contact
        return contact_result if contact_result.is_a?(Result)

        @contact = contact_result
        item_result = create_pipeline_item
        return item_result if item_result.is_a?(Result)

        Result.new(status: :created, contact: @contact, pipeline_item: item_result)
      end

      # Scoped to the destination pipeline: purchase ids are only unique within
      # one platform account, and the registered URL pins the pipeline.
      def find_existing_item
        @pipeline.pipeline_items
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

        contact = find_contact(email, phone)
        contact ? update_existing_contact(contact, phone) : create_contact(email, phone)
      rescue ActiveRecord::RecordInvalid => e
        Result.new(status: :contact_error, details: { errors: e.record.errors.full_messages })
      end

      def find_contact(email, phone)
        (email && Contact.from_email(email)) || (phone && Contact.find_by(phone_number: phone))
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
        @contact_created = true
        contact
      rescue ActiveRecord::RecordNotUnique
        # Concurrent delivery won the insert (the uniqueness validation cannot
        # close that window). Take the row it created rather than 500.
        find_contact(email, phone) || raise
      end

      # Additive only: fill blanks, never overwrite. A phone that already belongs
      # to ANOTHER contact is skipped silently on the wire (logged) — naming the
      # owner would let a signed-but-curious platform enumerate contacts.
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
        return phone if phone.presence&.match?(E164)

        Rails.logger.warn("Purchase webhook: unusable phone on purchase #{@lead[:purchase_id]} " \
                          "(normalized to #{phone.inspect}) — captured without phone")
        nil
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
        active_card_result || Result.new(status: :pipeline_item_error, details: { errors: e.record.errors.full_messages })
      rescue ActiveRecord::RecordNotUnique => e
        # Two partial unique indexes can fire here; answer from the one that did.
        # A concurrent redelivery hits the purchase-identity index -> duplicate;
        # a DIFFERENT purchase for the same contact hits the active-card index.
        if (existing = find_existing_item)
          return Result.new(status: :duplicate, contact: existing.contact, pipeline_item: existing)
        end

        active_card_result || raise(e)
      end

      def active_card_result
        active = @pipeline.pipeline_items.active.find_by(contact_id: @contact.id)
        return nil unless active

        @extra_purchase_recorded = record_extra_purchase(active)
        Result.new(status: :already_in_pipeline, contact: @contact, pipeline_item: active)
      end

      # One open card per contact per pipeline, so a second sale gets no card of
      # its own. Append it to the open card instead of dropping it; idempotent,
      # so a redelivery of that second sale does not append twice.
      def record_extra_purchase(item)
        fields = item.custom_fields || {}
        purchase = card_custom_fields['purchase']
        return false if same_purchase?(fields['purchase'], purchase)

        history = Array(fields['purchases'])
        return false if history.any? { |entry| same_purchase?(entry, purchase) }

        item.update!(custom_fields: fields.merge('purchases' => history + [purchase]))
        true
      rescue ActiveRecord::ActiveRecordError => e
        Rails.logger.warn("Purchase webhook: could not append purchase #{@lead[:purchase_id]} to card #{item.id}: #{e.message}")
        false
      end

      def same_purchase?(entry, purchase)
        entry.is_a?(Hash) && entry['provider'] == purchase['provider'] && entry['purchase_id'] == purchase['purchase_id']
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
