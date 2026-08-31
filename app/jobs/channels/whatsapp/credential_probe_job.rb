class Channels::Whatsapp::CredentialProbeJob < ApplicationJob
  queue_as :low

  def perform(whatsapp_channel)
    whatsapp_channel.record_credential_probe!(probe(whatsapp_channel))
  end

  private

  # A probe that raises told us nothing about the credential: a timeout or a
  # provider outage is not a revocation, so it records the attempt and leaves
  # the state alone.
  def probe(channel)
    channel.provider_service.probe_credential
  rescue StandardError => e
    Rails.logger.warn("Credential probe failed for whatsapp channel #{channel.id}: #{e.message}")
    :inconclusive
  end
end
