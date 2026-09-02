module EvolutionHelper
  CHANNEL_LOCK_ON_OUTGOING_MESSAGE_KEY = 'EVOLUTION::CHANNEL_LOCK_ON_OUTGOING_MESSAGE::%<channel_id>s'.freeze
  CHANNEL_LOCK_ON_OUTGOING_MESSAGE_TIMEOUT = 15.seconds

  def evolution_extract_message_timestamp(timestamp)
    # Evolution API timestamp is usually in seconds or milliseconds
    timestamp = timestamp.to_i

    # If timestamp looks like it's in milliseconds (> 10^12), convert to seconds
    timestamp /= 1000 if timestamp > 10**12

    # Return Unix timestamp as integer
    timestamp
  rescue StandardError
    Time.current.to_i
  end

  def with_evolution_channel_lock_on_outgoing_message(channel_id, timeout: CHANNEL_LOCK_ON_OUTGOING_MESSAGE_TIMEOUT)
    raise ArgumentError, 'A block is required for with_evolution_channel_lock_on_outgoing_message' unless block_given?

    start_time = Time.now.to_i

    # NOTE: On timeout, we ignore the lock and proceed with the block execution
    while (Time.now.to_i - start_time) < timeout
      break if evolution_lock_channel_on_outgoing_message(channel_id, timeout)

      sleep(0.1)
    end

    yield
  ensure
    evolution_clear_channel_lock_on_outgoing_message(channel_id)
  end

  private

  def evolution_lock_channel_on_outgoing_message(channel_id, timeout)
    key = format(CHANNEL_LOCK_ON_OUTGOING_MESSAGE_KEY, channel_id: channel_id)
    Redis::Alfred.set(key, 1, nx: true, ex: timeout)
  end

  def evolution_clear_channel_lock_on_outgoing_message(channel_id)
    key = format(CHANNEL_LOCK_ON_OUTGOING_MESSAGE_KEY, channel_id: channel_id)
    Redis::Alfred.delete(key)
  end
end
