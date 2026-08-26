class AgentBots::HttpRequestJob < ApplicationJob
  queue_as :high

  # Mirrors AgentBots::WebhookJob: the listener must never hold its thread (and
  # whatever transaction/locks surround the event dispatch) across the bot's
  # HTTP round-trip, which includes model latency.
  def perform(agent_bot_id, payload)
    agent_bot = AgentBot.find_by(id: agent_bot_id)
    return if agent_bot.nil?

    AgentBots::HttpRequestService.new(agent_bot, payload).perform
  end
end
