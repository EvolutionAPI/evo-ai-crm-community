module PushDataHelper
  extend ActiveSupport::Concern

  def push_event_data
    Conversations::EventDataPresenter.new(self).push_data
  end

  def lock_event_data
    Conversations::EventDataPresenter.new(self).lock_data
  end

  # CRM-155: `labels_data` is for the realtime consumers only. Keeping it out of
  # the webhook body leaves customer integrations byte-for-byte unchanged, and
  # spares the labels query on every message webhook (Message#webhook_data
  # embeds this hash, and it is built before the "any webhook configured?"
  # check).
  def webhook_data
    Conversations::EventDataPresenter.new(self).push_data(include_labels_data: false)
  end
end
