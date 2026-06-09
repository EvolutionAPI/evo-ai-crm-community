# frozen_string_literal: true

class Webhooks::SendgridController < ApplicationController
  skip_before_action :authenticate_user!, raise: false

  # SendGrid posts an array of event objects. Each event is deduped and
  # processed independently; a single bad event never fails the batch.
  # Always returns 200 so SendGrid does not retry the whole payload.
  def create
    events = parse_events
    events.each { |event| process_event(event) }
    render json: { received: events.size }, status: :ok
  end

  private

  def parse_events
    raw_body = request.body.read
    request.body.rewind
    parsed = JSON.parse(raw_body)
    parsed.is_a?(Array) ? parsed : [parsed]
  rescue JSON::ParserError => e
    Rails.logger.warn("[SENDGRID_WEBHOOK] invalid JSON payload: #{e.message}")
    []
  end

  def process_event(event)
    Sendgrid::EventProcessor.new(event).process
    true
  rescue StandardError => e
    Rails.logger.error("[SENDGRID_WEBHOOK] event processing failed: #{e.class}: #{e.message}")
    false
  end
end
