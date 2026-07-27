# frozen_string_literal: true

require 'rails_helper'

# Stand-in for ActiveStorage::Attached::One: its #blob is resolved dynamically
# (not a statically-defined instance method), so instance_double can't verify it.
# A small real object avoids a bare RSpec double while staying rubocop-clean.
class FakeAttachedFile
  def initialize(attached:, blob:)
    @attached = attached
    @blob = blob
  end

  def attached?
    @attached
  end

  attr_reader :blob
end

RSpec.describe BotRuntime::AttachmentBuilder do
  subject(:built) { described_class.build('42') }

  let(:t) { Time.zone.now }

  def attachment(file_type:, attached: true, with_file: true, content_type: 'audio/ogg', id: SecureRandom.uuid)
    blob = instance_double(ActiveStorage::Blob, content_type: content_type)
    file = FakeAttachedFile.new(attached: attached, blob: blob)
    att = instance_double(Attachment, id: id, created_at: t, file_type: file_type, file: file, with_attached_file?: with_file)
    allow(BlobUrlOptions).to receive(:outbound_media_url).with(blob).and_return("http://evo-crm:3000/rails/#{id}")
    att
  end

  def stub_message(attachments)
    message = instance_double(Message, attachments: attachments)
    relation = instance_double(ActiveRecord::Relation, find_by: message)
    allow(Message).to receive(:includes).and_return(relation)
    allow(relation).to receive(:find_by).with(id: '42').and_return(message)
    message
  end

  it 'builds a media payload for an attached audio file' do
    stub_message([attachment(file_type: 'audio', content_type: 'audio/ogg', id: 'a1')])
    expect(built).to eq([{ url: 'http://evo-crm:3000/rails/a1', content_type: 'audio/ogg', file_type: 'audio' }])
  end

  it 'skips an attachment whose file is not actually attached (download failed)' do
    stub_message([attachment(file_type: 'audio', attached: false)])
    expect(built).to eq([])
  end

  it 'skips an attachment with a blank file_type' do
    stub_message([attachment(file_type: '')])
    expect(built).to eq([])
  end

  it 'returns [] when the message has no attachments' do
    stub_message([])
    expect(built).to eq([])
  end

  it 'returns [] when the message is not found' do
    relation = instance_double(ActiveRecord::Relation, find_by: nil)
    allow(Message).to receive(:includes).and_return(relation)
    allow(relation).to receive(:find_by).with(id: '42').and_return(nil)
    expect(built).to eq([])
  end

  it 'returns [] for a blank message id' do
    expect(described_class.build(nil)).to eq([])
  end

  it 'is non-fatal: returns [] if lookup raises' do
    allow(Message).to receive(:includes).and_raise(StandardError, 'boom')
    expect(built).to eq([])
  end
end
