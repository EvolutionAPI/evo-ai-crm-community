# frozen_string_literal: true

require 'rails_helper'

# EVO-2179: BotRuntime::DelegationService must forward incoming media attachments to
# the bot_runtime. The @message it receives is an unpersisted Message.new (only id),
# so build_attachments reloads the persisted record via the conversation and maps its
# ActiveStorage media attachments to {url, content_type, file_type}.
#
# The collaborators are verifying doubles on purpose: the whole point of this spec is
# the mapping, so it must fail if the Attachment/Blob API it maps from drifts.
RSpec.describe BotRuntime::DelegationService do
  subject(:service) { described_class.new(agent_bot, message, conversation) }

  let(:agent_bot) do
    instance_double(AgentBot, id: 'bot-1', name: 'Agente', api_key: 'api-key',
                              outgoing_url: 'https://agent.example/webhook', debounce_time: 5,
                              message_signature: '', text_segmentation_enabled: false,
                              text_segmentation_limit: 300, text_segmentation_min_size: 50,
                              delay_per_character: 50)
  end
  let(:message) { instance_double(Message, id: 42, content: 'olha a foto') }
  let(:messages_relation) { instance_double(ActiveRecord::Relation) }
  let(:labels) { instance_double(ActiveRecord::Relation, pluck: ['vip']) }
  let(:contact) do
    instance_double(Contact, id: 'contact-1', name: 'Ana', email: 'ana@example.com',
                             phone_number: '+5511999999999', identifier: nil, type: 'person',
                             contact_type: 'lead', blocked: false, location: 'SP', country_code: 'BR',
                             additional_attributes: {}, custom_attributes: {}, labels: labels)
  end
  let(:inbox) { instance_double(Inbox, id: 'inbox-1', name: 'WhatsApp') }
  let(:conversation) do
    instance_double(Conversation, id: 'conv-1', display_id: 7, contact_id: 'contact-1',
                                  contact: contact, inbox: inbox, messages: messages_relation)
  end

  before do
    # The service preloads the blobs (no N+1 on the delegation hot path).
    allow(messages_relation).to receive(:includes).with(described_class::ATTACHMENT_PRELOAD).and_return(messages_relation)
  end

  # ActiveStorage::Attached::One delegates #blob to the attachment record through
  # method_missing, so a verifying double cannot stand in for it — the file wrapper
  # is the only plain double here.
  def attachment(file_type:, **opts)
    url = opts.fetch(:url, 'https://crm.example.com/rails/active_storage/blobs/proxy/photo.png')
    blob = instance_double(ActiveStorage::Blob, content_type: opts.fetch(:content_type, 'image/png'))
    file = double('ActiveStorage::Attached::One', attached?: opts.fetch(:attached, true), blob: blob)
    # Outbound media URL (ACTIVE_STORAGE_URL host + 15min TTL), not the permanent
    # browser-facing Attachment#download_url — the bot_runtime fetches it server-side.
    allow(BlobUrlOptions).to receive(:outbound_media_url).with(blob).and_return(url)
    instance_double(Attachment, file: file, with_attached_file?: opts.fetch(:with_attached, true),
                                file_type: file_type, id: opts.fetch(:id, 'att-1'),
                                created_at: opts.fetch(:created_at, Time.zone.local(2026, 7, 20, 12, 0, 0)))
  end

  def stub_persisted_with(attachments)
    persisted = instance_double(Message, attachments: attachments)
    allow(messages_relation).to receive(:find_by).with(id: 42).and_return(persisted)
  end

  # The rest of this file is doubles, so a preload path or URL helper that stopped
  # resolving would go unnoticed: build_attachments rescues to [] and the agent
  # just stops seeing images. These check them against the real classes, no DB.
  describe 'contract with the models it reads through' do
    it 'preloads a path that every model in it actually declares' do
      walk = lambda do |owner, spec|
        next if owner.nil?

        case spec
        when Symbol
          reflection = owner.reflect_on_association(spec)
          expect(reflection).not_to(
            be_nil, "#{owner}.#{spec} no longer exists — build_attachments would rescue to [] on every media message"
          )
          reflection&.klass
        when Hash
          spec.each { |association, nested| walk.call(walk.call(owner, association), nested) }
        end
      end

      walk.call(Message, described_class::ATTACHMENT_PRELOAD)
    end

    it 'reads the attachment fields it maps from' do
      expect(Attachment.new).to respond_to(:file, :file_type, :with_attached_file?)
    end

    it 'builds the outbound URL through the same helper the WhatsApp providers use' do
      expect(BlobUrlOptions).to respond_to(:outbound_media_url)
    end
  end

  describe '#build_attachments' do
    it 'reloads the persisted message and maps media attachments' do
      stub_persisted_with([attachment(file_type: 'image')])

      expect(service.send(:build_attachments)).to eq(
        [{
          url: 'https://crm.example.com/rails/active_storage/blobs/proxy/photo.png',
          content_type: 'image/png',
          file_type: 'image'
        }]
      )
    end

    it 'maps multiple media attachments in the order the contact sent them' do
      image = attachment(file_type: 'image', content_type: 'image/jpeg', url: 'https://c/img.jpg',
                         created_at: Time.zone.local(2026, 7, 20, 12, 0, 0), id: 'att-img')
      audio = attachment(file_type: 'audio', content_type: 'audio/ogg', url: 'https://c/a.ogg',
                         created_at: Time.zone.local(2026, 7, 20, 12, 0, 1), id: 'att-audio')
      stub_persisted_with([audio, image]) # DB order is not guaranteed

      result = service.send(:build_attachments)
      expect(result.map { |a| a[:file_type] }).to eq(%w[image audio])
      expect(result.map { |a| a[:content_type] }).to eq(['image/jpeg', 'audio/ogg'])
    end

    it 'returns [] when the persisted message is not found' do
      allow(messages_relation).to receive(:find_by).with(id: 42).and_return(nil)
      expect(service.send(:build_attachments)).to eq([])
    end

    it 'skips attachments whose file is not attached' do
      stub_persisted_with([attachment(file_type: 'image', attached: false)])
      expect(service.send(:build_attachments)).to eq([])
    end

    it 'skips non-media attachments (e.g. location)' do
      stub_persisted_with([attachment(file_type: 'location', with_attached: false)])
      expect(service.send(:build_attachments)).to eq([])
    end

    it 'skips attachments with no file_type instead of blowing up' do
      stub_persisted_with([attachment(file_type: nil)])
      expect(service.send(:build_attachments)).to eq([])
    end

    it 'keeps the healthy attachments when one of them raises' do
      broken = instance_double(Attachment, file_type: 'image', id: 'att-boom',
                                           created_at: Time.zone.local(2026, 7, 20, 12, 0, 0))
      allow(broken).to receive(:file).and_raise(StandardError, 'blob vanished')
      good = attachment(file_type: 'audio', content_type: 'audio/ogg', url: 'https://c/a.ogg',
                        created_at: Time.zone.local(2026, 7, 20, 12, 0, 1), id: 'att-audio')
      stub_persisted_with([broken, good])
      allow(Rails.logger).to receive(:error)

      result = service.send(:build_attachments)

      expect(result.map { |a| a[:file_type] }).to eq(%w[audio])
      expect(Rails.logger).to have_received(:error).with(/attachment att-boom failed .*message=42/)
    end

    it 'does not query at all when the payload announced no attachments' do
      service = described_class.new(agent_bot, message, conversation, has_attachments: false)
      expect(messages_relation).not_to receive(:includes)

      expect(service.send(:build_attachments)).to eq([])
    end

    it 'never raises: logs and returns [] on error' do
      allow(messages_relation).to receive(:find_by).and_raise(StandardError.new('boom'))
      allow(Rails.logger).to receive(:error)

      expect(service.send(:build_attachments)).to eq([])
      expect(Rails.logger).to have_received(:error).with(/build_attachments failed/)
    end
  end

  describe '#build_message_event' do
    before { allow(BotRuntime::Config).to receive(:postback_base_url).and_return('https://crm.example.com') }

    # The wire contract with the Go service: MessageEvent.Attachments is bound from
    # the snake_case "attachments" key (evo-bot-runtime pkg/pipeline/model/pipeline.go).
    it 'ships the mapped attachments under the :attachments key' do
      stub_persisted_with([attachment(file_type: 'image', url: 'https://crm.example.com/img.png')])

      event = service.send(:build_message_event)

      expect(event[:attachments]).to eq(
        [{ url: 'https://crm.example.com/img.png', content_type: 'image/png', file_type: 'image' }]
      )
      expect(event.keys).to include(:agent_bot_id, :conversation_id, :contact_id, :message_id, :message_content,
                                    :attachments, :api_key, :outgoing_url, :bot_config, :postback_url, :metadata)
    end

    it 'sends an empty list when the message has no attachments' do
      stub_persisted_with([])

      expect(service.send(:build_message_event)[:attachments]).to eq([])
    end
  end
end
