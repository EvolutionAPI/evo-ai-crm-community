require 'rails_helper'

# F6/F7: EvoFlow::EVENT_NAMES lives in lib/events/ with a constant name that
# does not match the Zeitwerk path; loading is handled by an ignore + explicit
# require in config/application.rb. This spec is the regression guard: if a
# future refactor breaks that wiring (or production eager_load), it fails here
# instead of only at deploy time.
RSpec.describe 'EvoFlow::EVENT_NAMES' do
  it 'is a frozen Array<String> of exactly the 22 events (AC6 + EVO-1245 backfill extension + custom sentinel)' do
    expect(EvoFlow::EVENT_NAMES).to be_frozen
    expect(EvoFlow::EVENT_NAMES).to all(be_a(String))
    expect(EvoFlow::EVENT_NAMES).to contain_exactly(
      'contact.created', 'contact.updated', 'contact.deleted',
      'contact.label.added', 'contact.label.removed', 'contact.custom_attribute.changed',
      'conversation.created', 'conversation.resolved',
      'conversation.activity', 'conversation.first_reply', 'conversation.reply_time',
      'conversation.bot_handoff', 'conversation.bot_resolved',
      'message.created', 'message.delivered', 'message.read', 'message.failed',
      'campaign.triggered', 'campaign.message.sent',
      'campaign.message.opened', 'campaign.message.clicked',
      'custom'
    )
  end

  it 'includes the 5 backfill-only event names added in EVO-1245' do
    expect(EvoFlow::EVENT_NAMES).to include(
      'conversation.activity',
      'conversation.first_reply',
      'conversation.reply_time',
      'conversation.bot_handoff',
      'conversation.bot_resolved'
    )
  end

  it 'production-style eager_load does not raise (Zeitwerk wiring intact)' do
    expect { Rails.application.eager_load! }.not_to raise_error
  end

  it 'autoloads the EvoFlow:: app classes alongside the lib constant' do
    expect(EvoFlow::Client).to be < Object
    expect(EvoFlow::PayloadBuilder).to be < Object
    expect(EvoFlow::PublishEventWorker).to be < Object
    expect(EvoFlow::HTTPError).to be < StandardError
    expect(EvoFlow::ConfigurationError).to be < StandardError
    expect(EvoFlow::InvalidEventName).to be < StandardError
  end
end
