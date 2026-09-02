class AgentBots::HttpRequestJob < ApplicationJob
  queue_as :high

  # Mirrors AgentBots::WebhookJob: the listener must never hold its thread (and
  # whatever transaction/locks surround the event dispatch) across the bot's
  # HTTP round-trip, which includes model latency.
  def perform(agent_bot_id, payload)
    agent_bot = AgentBot.find_by(id: agent_bot_id)
    # agent_bots is RLS-scoped on enterprise, so a job that lands without its
    # tenant reads nil here and the bot simply never answers. Log it: unlike the
    # inline call this replaces, nothing else marks the failure.
    if agent_bot.nil?
      Rails.logger.warn "[AgentBot HTTP] Bot #{agent_bot_id} not found - skipping (deleted, or job ran without its tenant)"
      return
    end

    AgentBots::HttpRequestService.new(agent_bot, payload).perform
  end
end
