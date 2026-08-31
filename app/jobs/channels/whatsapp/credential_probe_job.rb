class Channels::Whatsapp::CredentialProbeJob < ApplicationJob
  queue_as :low

  def perform(whatsapp_channel)
    whatsapp_channel.record_credential_probe!(probe(whatsapp_channel))
  end

  private

  # A probe that raises told us nothing about the credential — a timeout or a
  # provider 502 is not a revocation. It still counts as a failed probe: the
  # reauthorization threshold is what separates one bad answer from a channel
  # that is really down, so a blip costs a count and a revocation costs the
  # channel.
  def probe(channel)
    channel.provider_service.validate_provider_config?
  rescue StandardError => e
    Rails.logger.warn("Credential probe failed for whatsapp channel #{channel.id}: #{e.message}")
    false
  end
end
