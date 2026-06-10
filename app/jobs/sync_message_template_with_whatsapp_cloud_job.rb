# frozen_string_literal: true

# Pushes a MessageTemplate up to Meta (WhatsApp Cloud) for approval and lets the
# existing create_template -> sync_templates path write back the Meta template id
# (metadata['external_id']) and approval status (settings['status'] = 'PENDING')
# onto the same record. (EVO-1232)
class SyncMessageTemplateWithWhatsappCloudJob < ApplicationJob
  queue_as :low

  def perform(message_template)
    channel = message_template.channel

    unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
      Rails.logger.warn(
        "[EVO-1232] sync skipped for template #{message_template.id}: not bound to a WhatsApp Cloud channel"
      )
      return
    end

    # channel.create_template pushes to Meta and then re-syncs, landing
    # metadata['external_id'] + settings['status']='PENDING' on this record.
    channel.create_template(
      'name' => message_template.name,
      'category' => message_template.category,
      'language' => message_template.language,
      'components' => meta_components(message_template)
    )
  rescue StandardError => e
    # Publishing to Meta is non-idempotent (a template name can only be created
    # once), so we do NOT re-raise: a Sidekiq retry would re-publish and error on
    # the duplicate name. The action is user-triggered and re-runnable, so log and
    # stop. (EVO-1232 / adversarial review F14)
    Rails.logger.error(
      "[EVO-1232] WhatsApp Cloud template sync failed for #{message_template.id}: #{e.message}"
    )
  end

  private

  # Persisted components are stored either as Meta's Array-of-components (when the
  # template was authored via the API/global menu) or as a Hash keyed by
  # lowercase type (when pulled back from Meta by sync_template_to_database).
  # Whatsapp::Providers::WhatsappCloudService#process_template_components expects
  # the Array form, so normalize. (EVO-1232 / adversarial review F2)
  def meta_components(message_template)
    components = message_template.components
    return components if components.is_a?(Array)
    return components.values if components.is_a?(Hash)

    []
  end
end
