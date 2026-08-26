class Webhooks::FacebookController < ActionController::API
  # This controller handles feed changes (posts/comments) from Facebook webhook
  # The gem facebook-messenger handles messaging events via /bot route
  # Feed changes come in the same webhook payload but need separate processing

  def feed_events
    Rails.logger.info('Facebook feed webhook received')

    # Process feed changes from webhook payload
    # Payload structure: { "object": "page", "entry": [{ "id": "PAGE_ID", "changes": [...] }] }
    if params['object'].casecmp('page').zero? && params['entry'].present?
      process_feed_changes(params['entry'])
      render json: { status: 'received' }
    else
      Rails.logger.warn("Facebook feed webhook: Invalid payload structure - object: #{params['object']}")
      head :unprocessable_entity
    end
  end

  private

  def process_feed_changes(entries)
    entries.each do |entry|
      page_id = entry['id']
      changes = entry['changes'] || []

      next if changes.empty?

      Rails.logger.info("Processing #{changes.length} feed changes for page #{page_id}")

      changes.each do |change|
        # Only process feed field changes
        next unless change['field'] == 'feed'

        # Process feed change in background job
        Webhooks::FacebookFeedEventsJob.perform_later(change['value'], page_id: page_id)
      end
    end
  end
end

