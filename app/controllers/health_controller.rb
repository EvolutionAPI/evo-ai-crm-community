# frozen_string_literal: true

require 'prometheus/client'
require 'prometheus/client/formats/text'

class HealthController < ActionController::Base
  # GET /metrics - Prometheus metrics
  def metrics
    update_concurrent_users_metric
    render plain: metrics_payload,
           content_type: Prometheus::Client::Formats::Text::CONTENT_TYPE
  end

  # GET /health/live - Liveness probe
  def live
    render json: { status: 'alive' }, status: :ok
  end

  # GET /health/ready - Readiness probe
  def ready
    database_ok = check_database
    redis_ok = check_redis
    schema_state = check_schema

    is_ready = database_ok && redis_ok && schema_state == 'ok'

    render json: {
      ready: is_ready,
      checks: {
        database: database_ok ? 'ok' : 'failing',
        redis: redis_ok ? 'ok' : 'failing',
        schema: schema_state
      }
    }, status: is_ready ? :ok : :service_unavailable
  end

  private

  def check_database
    ActiveRecord::Base.connection.execute('SELECT 1')
    true
  rescue StandardError
    false
  end

  # A boot whose `db:migrate` aborted keeps serving requests over an INCOMPLETE schema:
  # liveness passes and dependents start against tables that do not exist.
  def check_schema
    migration_context.needs_migration? ? 'pending_migrations' : 'ok'
  rescue StandardError => e
    Rails.logger.error("[health] schema check failed: #{e.class}: #{e.message}")
    'check_failed'
  end

  # NOT the connection's default `migration_context`: that one resolves to just
  # ["db/migrate"], so migrations a mounted engine appends via initializer are invisible
  # to it and a pending engine migration would report ready.
  def migration_context
    paths = Rails.application.paths['db/migrate'].to_a
    return ActiveRecord::Base.connection.migration_context if paths.blank?

    ActiveRecord::MigrationContext.new(paths)
  end

  def check_redis
    Redis.new(Redis::Config.app).ping == 'PONG'
  rescue StandardError
    false
  end

  def update_concurrent_users_metric
    cache_key = 'metrics:crm:concurrent_users'
    lock_key = 'metrics:crm:concurrent_users:lock'

    value = Rails.cache.read(cache_key)

    if value.nil?
      lock_acquired = Redis::Alfred.set(lock_key, '1', nx: true, ex: 10)

      if lock_acquired
        value = OnlineStatusTracker.concurrent_users_count
        Rails.cache.write(cache_key, value, expires_in: 15.seconds)
      else
        value = Rails.cache.read(cache_key) || 0
      end
    end

    EVO_AI_CRM_CONCURRENT_USERS_GAUGE.set(value.to_i)
  rescue StandardError => e
    Rails.logger.error("Failed to update concurrent users metric: #{e.message}")
  end

  def metrics_payload
    base_payload = Prometheus::Client::Formats::Text.marshal(Prometheus::Client.registry)
    [base_payload, messages_total_metrics].join("\n")
  end

  def messages_total_metrics
    inbound = Redis::Alfred.get(Redis::Alfred::CRM_MESSAGES_TOTAL_INBOUND).to_i
    outbound = Redis::Alfred.get(Redis::Alfred::CRM_MESSAGES_TOTAL_OUTBOUND).to_i

    <<~METRICS
      # HELP evo_ai_crm_messages_total Total CRM messages by direction
      # TYPE evo_ai_crm_messages_total counter
      evo_ai_crm_messages_total{direction="inbound"} #{inbound}
      evo_ai_crm_messages_total{direction="outbound"} #{outbound}
    METRICS
  rescue StandardError => e
    Rails.logger.error("Failed to read message counters from Redis: #{e.message}")
    ''
  end
end
