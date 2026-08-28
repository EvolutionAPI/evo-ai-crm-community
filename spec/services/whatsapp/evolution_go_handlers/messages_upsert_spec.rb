# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionGoHandlers::MessagesUpsert' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::EvolutionGoHandlers::MessagesUpsert do
  let(:host_class) do
    Class.new do
      include Whatsapp::EvolutionGoHandlers::MessagesUpsert

      attr_writer :evolution_go_info, :evolution_go_message

      def initialize(info: nil, message: nil)
        @evolution_go_info = info
        @evolution_go_message = message
      end
    end
  end

  subject(:service) { host_class.new(info: info, message: evo_message) }

  let(:evo_message) { {} }
  let(:info) { nil }

  describe '#message_type_from_media' do
    context 'when @evolution_go_info is nil' do
      let(:info) { nil }

      context 'and message struct is videoMessage' do
        let(:evo_message) { { videoMessage: {} } }

        it 'returns video' do
          expect(service.send(:message_type_from_media)).to eq('video')
        end
      end

      context 'and message struct is imageMessage' do
        let(:evo_message) { { imageMessage: {} } }

        it 'returns image' do
          expect(service.send(:message_type_from_media)).to eq('image')
        end
      end

      context 'and message struct is documentMessage' do
        let(:evo_message) { { documentMessage: {} } }

        it 'returns file' do
          expect(service.send(:message_type_from_media)).to eq('file')
        end
      end

      context 'and message struct is audioMessage' do
        let(:evo_message) { { audioMessage: {} } }

        it 'returns audio' do
          expect(service.send(:message_type_from_media)).to eq('audio')
        end
      end

      context 'and message struct is stickerMessage' do
        let(:evo_message) { { stickerMessage: {} } }

        it 'returns sticker' do
          expect(service.send(:message_type_from_media)).to eq('sticker')
        end
      end
    end

    context 'when MediaType is blank string' do
      let(:info) { { MediaType: '' } }
      let(:evo_message) { { videoMessage: {} } }

      it 'falls back to struct-based detection and returns video' do
        expect(service.send(:message_type_from_media)).to eq('video')
      end
    end

    context 'when MediaType is present' do
      let(:evo_message) { {} }

      it 'returns image for MediaType=image' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'image' })
        expect(service.send(:message_type_from_media)).to eq('image')
      end

      it 'returns video for MediaType=video' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'video' })
        expect(service.send(:message_type_from_media)).to eq('video')
      end

      it 'returns audio for MediaType=audio' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'audio' })
        expect(service.send(:message_type_from_media)).to eq('audio')
      end

      it 'returns audio for MediaType=ptt' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'ptt' })
        expect(service.send(:message_type_from_media)).to eq('audio')
      end

      it 'returns file for MediaType=document' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'document' })
        expect(service.send(:message_type_from_media)).to eq('file')
      end

      it 'returns sticker for MediaType=sticker' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'sticker' })
        expect(service.send(:message_type_from_media)).to eq('sticker')
      end

      it 'returns file for unknown MediaType' do
        service.instance_variable_set(:@evolution_go_info, { MediaType: 'unknown_type' })
        expect(service.send(:message_type_from_media)).to eq('file')
      end
    end
  end

  # EVO-1908: control / empty-content messages must not produce blank bubbles
  # (paridade com EvolutionHandlers). Every skipped type below is asserted to
  # NOT call `create_message` when `handle_message` is exercised, and the
  # renderable types (reaction/location/contacts) round-trip real content
  # through `message_content`.
  describe '#ignore_message?' do
    {
      'protocol'    => { protocolMessage: { type: 'REVOKE' } },
      'unsupported' => { pollCreationMessage: { name: 'Choose' } },
      'reaction'    => { reactionMessage: { text: '👍', key: { id: 'abc' } } }
    }.each do |label, msg|
      it "skips #{label}" do
        service.instance_variable_set(:@evolution_go_message, msg)
        expect(service.send(:ignore_message?)).to be(true)
      end
    end

    it 'skips reaction removal (empty text)' do
      service.instance_variable_set(:@evolution_go_message, { reactionMessage: { text: '', key: { id: 'x' } } })
      expect(service.send(:ignore_message?)).to be(true)
    end

    it 'does NOT skip location (has renderable content)' do
      service.instance_variable_set(:@evolution_go_message,
                                    { locationMessage: { degreesLatitude: -23.5, degreesLongitude: -46.6 } })
      expect(service.send(:ignore_message?)).to be(false)
    end

    it 'does NOT skip contacts (has renderable content)' do
      service.instance_variable_set(:@evolution_go_message,
                                    { contactMessage: { displayName: 'Alice' } })
      expect(service.send(:ignore_message?)).to be(false)
    end

    it 'does NOT skip text' do
      service.instance_variable_set(:@evolution_go_message, { conversation: 'hi' })
      expect(service.send(:ignore_message?)).to be(false)
    end

    it 'does NOT skip media (blank caption still has attachment)' do
      service.instance_variable_set(:@evolution_go_message, { imageMessage: { mimetype: 'image/jpeg' } })
      expect(service.send(:ignore_message?)).to be(false)
    end
  end

  describe '#message_content (EVO-1908 parity extractors)' do
    it 'extracts reaction emoji text' do
      service.instance_variable_set(:@evolution_go_message, { reactionMessage: { text: '❤️' } })
      expect(service.send(:message_content)).to eq('❤️')
    end

    it 'renders location as "Location: <lat>, <long>"' do
      service.instance_variable_set(:@evolution_go_message,
                                    { locationMessage: { degreesLatitude: -23.55, degreesLongitude: -46.63 } })
      expect(service.send(:message_content)).to eq('Location: -23.55, -46.63')
    end

    it 'renders contactMessage displayName' do
      service.instance_variable_set(:@evolution_go_message, { contactMessage: { displayName: 'Bob' } })
      expect(service.send(:message_content)).to eq('Bob')
    end

    it 'falls back to vcard FN when displayName is missing' do
      vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Carol Souza\r\nEND:VCARD"
      service.instance_variable_set(:@evolution_go_message, { contactMessage: { vcard: vcard } })
      expect(service.send(:message_content)).to eq('Carol Souza')
    end

    it 'uses first entry of contactsArrayMessage.contacts' do
      service.instance_variable_set(:@evolution_go_message,
                                    { contactsArrayMessage: { contacts: [{ displayName: 'Dave' }, { displayName: 'Eve' }] } })
      expect(service.send(:message_content)).to eq('Dave')
    end

    it 'falls back to "Contact" when no name is extractable' do
      service.instance_variable_set(:@evolution_go_message, { contactMessage: { vcard: 'BEGIN:VCARD\nEND:VCARD' } })
      expect(service.send(:message_content)).to eq('Contact')
    end
  end

  describe '#unwrap_ephemeral_message!' do
    it 'replaces @evolution_go_message with the inner disappearing payload' do
      inner = { conversation: 'ghost message' }
      service.instance_variable_set(:@evolution_go_message, { ephemeralMessage: { message: inner } })
      service.send(:unwrap_ephemeral_message!)
      expect(service.instance_variable_get(:@evolution_go_message)).to eq(inner)
    end

    it 'is a no-op when message is not ephemeral' do
      original = { conversation: 'hi' }
      service.instance_variable_set(:@evolution_go_message, original)
      service.send(:unwrap_ephemeral_message!)
      expect(service.instance_variable_get(:@evolution_go_message)).to eq(original)
    end

    it 'is a no-op when ephemeralMessage carries no inner payload' do
      service.instance_variable_set(:@evolution_go_message, { ephemeralMessage: {} })
      expect { service.send(:unwrap_ephemeral_message!) }.not_to raise_error
    end

    it 'lets classification see the inner type after unwrap' do
      service.instance_variable_set(:@evolution_go_message,
                                    { ephemeralMessage: { message: { conversation: 'ghost' } } })
      service.send(:unwrap_ephemeral_message!)
      expect(service.send(:message_type)).to eq('text')
      expect(service.send(:message_content)).to eq('ghost')
    end
  end

  describe '#handle_message (EVO-1908 — no empty bubbles)' do
    let(:info) { { ID: 'msg-1', IsFromMe: false, Chat: '5511@s.whatsapp.net' } }

    before do
      # Avoid touching Rails DB: assert we never reach the create path for skipped types.
      allow(service).to receive(:message_processable?).and_return(true)
      allow(service).to receive(:set_contact)
      allow(service).to receive(:set_conversation)
      allow(service).to receive(:update_conversation_status_if_needed)
      service.instance_variable_set(:@contact_inbox, double('contact_inbox'))
    end

    {
      'reaction'    => { reactionMessage: { text: '👍', key: { id: 'x' } } },
      'poll'        => { pollCreationMessage: { name: 'p' } },
      'unsupported' => { messageContextInfo: {} },
      'edited'      => { editedMessage: { message: { conversation: 'x' } } }
    }.each do |label, msg|
      it "does not call create_message for #{label}" do
        service.instance_variable_set(:@evolution_go_message, msg)
        expect(service).not_to receive(:create_message)
        service.send(:handle_message)
      end
    end

    it 'unwraps ephemeral text and proceeds to create_message with real content' do
      inner = { conversation: 'ghost' }
      service.instance_variable_set(:@evolution_go_message, { ephemeralMessage: { message: inner } })
      expect(service).to receive(:create_message).with(attach_media: false)
      service.send(:handle_message)
      expect(service.instance_variable_get(:@evolution_go_message)).to eq(inner)
      expect(service.send(:message_content)).to eq('ghost')
    end

    it 'reaches create_message for location (renderable content)' do
      service.instance_variable_set(:@evolution_go_message,
                                    { locationMessage: { degreesLatitude: 1.0, degreesLongitude: 2.0 } })
      expect(service).to receive(:create_message).with(attach_media: false)
      service.send(:handle_message)
    end

    it 'reaches create_message for contacts (renderable content)' do
      service.instance_variable_set(:@evolution_go_message, { contactMessage: { displayName: 'Alice' } })
      expect(service).to receive(:create_message).with(attach_media: false)
      service.send(:handle_message)
    end
  end

  describe '#audio_voice_note?' do
    it 'returns false without raising when @evolution_go_info is nil' do
      service.instance_variable_set(:@evolution_go_info, nil)
      expect { service.send(:audio_voice_note?) }.not_to raise_error
      expect(service.send(:audio_voice_note?)).to be(false)
    end

    it 'returns true when MediaType is ptt' do
      service.instance_variable_set(:@evolution_go_info, { MediaType: 'ptt' })
      expect(service.send(:audio_voice_note?)).to be(true)
    end

    it 'returns false when MediaType is audio' do
      service.instance_variable_set(:@evolution_go_info, { MediaType: 'audio' })
      expect(service.send(:audio_voice_note?)).to be(false)
    end
  end
end
