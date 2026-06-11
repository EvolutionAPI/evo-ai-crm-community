# frozen_string_literal: true

require 'prometheus/client'
require 'prometheus/client/formats/text'

# Initialize Prometheus registry with default metrics
Prometheus::Client.registry

unless defined?(EVO_AI_CRM_CONCURRENT_USERS_GAUGE)
  EVO_AI_CRM_CONCURRENT_USERS_GAUGE = Prometheus::Client.registry.gauge(
    :evo_ai_crm_concurrent_users,
    docstring: 'Concurrent CRM users in the current presence window'
  )
end

# EVO-1234 [6.5] Legacy-template migration counters. Best-effort instrumentation:
# they increment in the Sidekiq worker process and are NOT visible to the web
# /metrics scrape (and reset per process). The migration's source of truth is its
# returned summary Hash + structured log, not these counters.
unless defined?(EVO_AI_CRM_TEMPLATES_MIGRATED_COUNTER)
  EVO_AI_CRM_TEMPLATES_MIGRATED_COUNTER = Prometheus::Client.registry.counter(
    :templates_migrated_total,
    docstring: 'Legacy channel-coupled templates migrated into the global flow',
    labels: [:source]
  )
end

unless defined?(EVO_AI_CRM_TEMPLATES_MIGRATED_SKIPPED_COUNTER)
  EVO_AI_CRM_TEMPLATES_MIGRATED_SKIPPED_COUNTER = Prometheus::Client.registry.counter(
    :templates_migrated_skipped,
    docstring: 'Legacy templates skipped during migration to the global flow',
    labels: [:reason]
  )
end
