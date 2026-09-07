# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationMailbox do
  it 'sanitizes In-Reply-To before the routing predicate queries PostgreSQL' do
    mail = Mail.new
    allow(mail).to receive(:in_reply_to).and_return("external\u0000@example.com")
    inbound = Struct.new(:mail).new(mail)

    expect { described_class.in_reply_to_mail?(inbound) }.not_to raise_error
    expect(described_class.in_reply_to_mail?(inbound)).to be(false)
  end

  it 'preserves conversation reference routing' do
    mail = Mail.new
    mail.in_reply_to = 'conversation/6bdc3f4d-0bec-4515-a284-5d916fdde489/messages/123@support.example.com'
    inbound = Struct.new(:mail).new(mail)

    expect(described_class.in_reply_to_mail?(inbound)).to be(true)
  end
end
