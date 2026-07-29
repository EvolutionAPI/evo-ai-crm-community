# frozen_string_literal: true

# Which providers each AI feature can actually talk to (FR18).
#
# AI Agents reach every provider through the core service. The other consumers
# build a `POST /chat/completions` call in `lib/integrations/openai_base_service.rb`,
# so a non-OpenAI provider there is not a misconfiguration — it is a different
# protocol, and calling it would fail at the wire.
#
# Stories 1.3 and 1.4 register their consumers here; the resolver needs no change.
class Ai::ConsumerCompatibility
  ALL_PROVIDERS = :all

  CONSUMERS = {
    ai_agents: ALL_PROVIDERS,
    inbox_assist: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS,
    audio_transcription: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS,
    label_suggestion: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS,
    moderation: Ai::Credential::OPENAI_COMPATIBLE_PROVIDERS
  }.freeze

  class << self
    def known?(consumer)
      CONSUMERS.key?(consumer&.to_sym)
    end

    def accepted_providers(consumer)
      CONSUMERS[consumer&.to_sym]
    end

    def accepts?(consumer, provider)
      accepted = accepted_providers(consumer)
      return false if accepted.nil?
      return true if accepted == ALL_PROVIDERS

      accepted.include?(provider)
    end
  end
end
