module PushDataHelper
  extend ActiveSupport::Concern

  def push_event_data
    Conversations::EventDataPresenter.new(self).push_data
  end

  def lock_event_data
    Conversations::EventDataPresenter.new(self).lock_data
  end

  # `labels_data` is realtime-only: leaving it out keeps customer integrations
  # byte-for-byte unchanged and spares the labels query on every message webhook
  # (Message#webhook_data embeds this hash, built before the "any webhook?" check).
  def webhook_data
    Conversations::EventDataPresenter.new(self).push_data(include_labels_data: false)
  end
end
