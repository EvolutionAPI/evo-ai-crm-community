require 'rails_helper'

# EVO-1267: shared {{root.path}} resolution engine, extracted from the
# Automation Rules executors so Messages::MessageBuilder (and therefore the
# evo-flow journey runtime) renders variables through the same code.
RSpec.describe TemplateVariableResolver do
  subject(:resolver) { described_class.new(conversation) }

  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'João', email: "joao-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  describe '#resolve_value' do
    it 'resolves contact dot-paths' do
      expect(resolver.resolve_value('Hi {{contact.name}}')).to eq('Hi João')
    end

    it 'resolves conversation dot-paths' do
      expect(resolver.resolve_value('#{{conversation.display_id}}')).to eq("##{conversation.display_id}")
    end

    it 'resolves multiple placeholders in one string (custom expression)' do
      expect(resolver.resolve_value('{{contact.name}} ({{contact.email}})')).to eq("João (#{contact.email})")
    end

    it 'replaces undefined fields with an empty string without raising' do
      expect(resolver.resolve_value('v: {{contact.nonexistent_field}}')).to eq('v: ')
    end

    it 'replaces unknown roots with an empty string' do
      expect(resolver.resolve_value('{{webhook.response}}')).to eq('')
    end

    it 'passes non-string values through untouched' do
      expect(resolver.resolve_value(42)).to eq(42)
    end

    it 'refuses dangerous segments instead of invoking them' do
      expect(resolver.resolve_value('{{contact.destroy}}')).to eq('')
      expect(contact.reload).to be_persisted
    end

    it 'refuses zero-arg-invocable writer/utility segments' do
      %w[update_columns update_attribute increment reload touch freeze].each do |segment|
        expect(resolver.resolve_value("{{contact.#{segment}}}")).to eq('')
      end
    end

    # EVO-1267 review B1: the perimeter is a default-deny allowlist, so reader
    # traversal off the curated surface — credential associations, mass-dump
    # serializers, bare roots — never resolves, regardless of the channel type.
    it 'refuses association traversal into channel credentials' do
      %w[
        conversation.inbox.channel.provider_config
        conversation.inbox.channel.api_key
        conversation.inbox.channel.page_access_token
        conversation.inbox.channel.user_access_token
      ].each do |path|
        expect(resolver.resolve_value("{{#{path}}}")).to eq('')
      end
    end

    it 'refuses mass-dump readers and bare roots' do
      %w[contact.attributes contact.to_json conversation.as_json conversation.inspect contact conversation].each do |path|
        expect(resolver.resolve_value("{{#{path}}}")).to eq('')
      end
    end
  end

  describe '#resolve_path with pipeline root' do
    let(:pipeline) { Pipeline.create!(name: 'Sales', pipeline_type: 'sales', created_by: user) }
    let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Lead', position: 1) }

    it 'resolves against the most recent pipeline item of the conversation' do
      PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation)

      expect(resolver.resolve_value('{{pipeline.pipeline_stage_id}}')).to eq(stage.id.to_s)
    end

    it 'yields empty string when the conversation has no pipeline item' do
      expect(resolver.resolve_value('{{pipeline.id}}')).to eq('')
    end
  end

  describe '#resolve_params' do
    it 'resolves every value and applies fallbacks on blank resolution' do
      params = { 'first_name' => '{{contact.name}}', 'deal' => '{{contact.deal_value}}', 'code' => 'ABC' }
      fallbacks = { 'deal' => 'sem valor' }

      expect(resolver.resolve_params(params, fallbacks)).to eq(
        'first_name' => 'João', 'deal' => 'sem valor', 'code' => 'ABC'
      )
    end

    it 'leaves blank resolutions empty when no fallback is given' do
      expect(resolver.resolve_params({ 'x' => '{{contact.deal_value}}' })).to eq('x' => '')
    end

    it 'returns non-hash input untouched' do
      expect(resolver.resolve_params(nil)).to be_nil
    end
  end
end
