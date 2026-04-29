# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'RegexHelper' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe RegexHelper do
  describe 'WHATSAPP_CHANNEL_REGEX' do
    it 'accepts plain phone numbers (with or without +)' do
      expect(described_class::WHATSAPP_CHANNEL_REGEX.match?('+5511999999999')).to be true
      expect(described_class::WHATSAPP_CHANNEL_REGEX.match?('5511999999999')).to be true
    end

    it 'accepts @lid identifiers' do
      expect(described_class::WHATSAPP_CHANNEL_REGEX.match?('12345678@lid')).to be true
    end

    it 'accepts BSUID-style identifiers' do
      expect(described_class::WHATSAPP_CHANNEL_REGEX.match?('BR.123abc')).to be true
    end

    it 'accepts modern group JIDs (single long number)' do
      expect(described_class::WHATSAPP_CHANNEL_REGEX.match?('120363025801848701@g.us')).to be true
    end

    it 'accepts legacy group JIDs (creator-timestamp format)' do
      expect(described_class::WHATSAPP_CHANNEL_REGEX.match?('553184455827-1593702061@g.us')).to be true
    end

    it 'rejects non-matching strings' do
      expect(described_class::WHATSAPP_CHANNEL_REGEX.match?('garbage')).to be false
      expect(described_class::WHATSAPP_CHANNEL_REGEX.match?('@g.us')).to be false
      expect(described_class::WHATSAPP_CHANNEL_REGEX.match?('not-a-jid@somewhere')).to be false
    end
  end
end
