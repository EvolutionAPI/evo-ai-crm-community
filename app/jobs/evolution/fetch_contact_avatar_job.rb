# frozen_string_literal: true

# Async fetch of a contact's WhatsApp profile picture via Evolution API.
# Mirrors the EvolutionGo::FetchContactAvatarWithFallbackJob pattern: this job
# resolves the picture URL through the provider service and hands the actual
# download off to Avatar::AvatarFromUrlJob, so neither the message ingestion
# path nor the avatar attach path block on a flaky external call.
class Evolution::FetchContactAvatarJob < ApplicationJob
  queue_as :low

  retry_on Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, wait: :polynomially_longer, attempts: 5
  retry_on HTTParty::ResponseError, HTTParty::Error, wait: :polynomially_longer, attempts: 3

  def perform(contact_id, phone_number, channel_id)
    contact = Contact.find_by(id: contact_id)
    return unless contact
    return if contact.avatar.attached?

    channel = Channel::Whatsapp.find_by(id: channel_id)
    return unless channel

    Rails.logger.info "Evolution API: Fetching profile picture URL for contact #{contact.id}"

    profile_picture_url = Whatsapp::Providers::EvolutionService
                            .new(whatsapp_channel: channel)
                            .fetch_profile_picture_url(phone_number)

    if profile_picture_url.present?
      Rails.logger.info "Evolution API: Scheduling avatar download for contact #{contact.id}"
      Avatar::AvatarFromUrlJob.perform_later(contact, profile_picture_url)
    else
      Rails.logger.debug { "Evolution API: No profile picture available for contact #{contact.id}" }
    end
  end
end
