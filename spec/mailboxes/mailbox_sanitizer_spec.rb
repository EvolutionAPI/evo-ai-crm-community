# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MailboxSanitizer do
  let(:sanitizer) { Class.new { include MailboxSanitizer }.new }

  it 'removes NUL bytes from nested email data without changing other values or mutating the input' do
    value = { text: "Hello\u0000 world", headers: ["subject\u0000", { reply: "id\u0000" }], count: 2, flag: false, empty: nil }
    cleaned = sanitizer.send(:sanitize_mailbox_value, value)

    expect(cleaned).to eq(text: 'Hello world', headers: ['subject', { reply: 'id' }], count: 2, flag: false, empty: nil)
    expect(value[:text]).to eq("Hello\u0000 world")
  end

  it 'preserves Unicode text and newlines' do
    expect(sanitizer.send(:sanitize_mailbox_value, "Olá\n世界\u0000")).to eq("Olá\n世界")
  end
end

