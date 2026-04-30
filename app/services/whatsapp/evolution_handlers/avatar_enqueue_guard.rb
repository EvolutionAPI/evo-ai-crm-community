# frozen_string_literal: true

# Single chokepoint for enqueueing Evolution::FetchContactAvatarJob. Prevents
# the same contact from being requeued from messages.upsert / contacts.update /
# contacts.upsert in rapid succession, and adds jitter for bulk-sync paths so a
# 50k-contact reconnect does not fan out 150k jobs into the :low queue at once.
module Whatsapp::EvolutionHandlers::AvatarEnqueueGuard
  AVATAR_ENQUEUE_LOCK_KEY = 'EVOLUTION::AVATAR_ENQUEUE_LOCK::%<contact_id>s'.freeze
  AVATAR_ENQUEUE_LOCK_TTL = 1.hour
  BULK_SYNC_JITTER_SECONDS = 600

  module_function

  def enqueue_avatar_fetch(contact_id:, phone_number:, channel_id:, jitter: false)
    return unless contact_id && channel_id && phone_number.present?
    return unless acquire_avatar_enqueue_lock(contact_id)

    if jitter
      Evolution::FetchContactAvatarJob
        .set(wait: rand(0..BULK_SYNC_JITTER_SECONDS).seconds)
        .perform_later(contact_id, phone_number, channel_id)
    else
      Evolution::FetchContactAvatarJob.perform_later(contact_id, phone_number, channel_id)
    end
  end

  def enqueue_avatar_download(contact, avatar_url)
    return unless contact && avatar_url.present?
    return unless acquire_avatar_enqueue_lock(contact.id)

    Avatar::AvatarFromUrlJob.perform_later(contact, avatar_url)
  end

  def acquire_avatar_enqueue_lock(contact_id)
    key = format(AVATAR_ENQUEUE_LOCK_KEY, contact_id: contact_id)
    Redis::Alfred.set(key, 1, nx: true, ex: AVATAR_ENQUEUE_LOCK_TTL.to_i) ? true : false
  end
end
