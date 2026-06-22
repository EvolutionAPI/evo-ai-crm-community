# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataImportJob, type: :job do
  let!(:contact) { Contact.create!(name: 'Maria', identifier: "cust-#{SecureRandom.hex(4)}") }

  let(:csv_body) do
    [
      'conversation_external_id,contact_identifier,message_content,direction,sent_at,sender_name,message_type,message_external_id',
      "conv-j1,#{contact.identifier},Hi,incoming,2026-01-15T10:30:00Z,,text,msg-j1"
    ].join("\n")
  end

  it 'dispatches conversation flow when data_type=conversations' do
    data_import = DataImport.create!(data_type: 'conversations')
    data_import.import_file.attach(io: StringIO.new(csv_body), filename: 'c.csv', content_type: 'text/csv')

    described_class.new.perform(data_import)

    data_import.reload
    expect(data_import.status).to eq('completed')
    expect(data_import.total_records).to eq(1)
    expect(data_import.processed_records).to eq(1)
    report = JSON.parse(data_import.processing_errors)
    expect(report['success_count']).to eq(1)
    expect(report['errors']).to eq([])
    expect(Conversation.find_by(identifier: 'conv-j1')).to be_present
  end

  it 'attaches failed_records CSV when rows are rejected' do
    csv = [
      'conversation_external_id,contact_identifier,message_content,direction,sent_at,sender_name,message_type,message_external_id',
      'conv-j2,unknown-id,Hi,incoming,2026-01-15T10:30:00Z,,text,msg-j2'
    ].join("\n")
    data_import = DataImport.create!(data_type: 'conversations')
    data_import.import_file.attach(io: StringIO.new(csv), filename: 'c.csv', content_type: 'text/csv')

    described_class.new.perform(data_import)

    data_import.reload
    expect(data_import.failed_records).to be_attached
    body = data_import.failed_records.download
    expect(body).to include('errors')
    expect(body).to include('contact not found')
  end

  it 'marks status as failed when CSV is malformed' do
    data_import = DataImport.create!(data_type: 'conversations')
    data_import.import_file.attach(io: StringIO.new("just,one\n"), filename: 'c.csv', content_type: 'text/csv')

    described_class.new.perform(data_import)

    expect(data_import.reload.status).to eq('failed')
  end

  it 'M4 — does NOT send contact_import_failed mailer when conversations CSV is malformed' do
    data_import = DataImport.create!(data_type: 'conversations')
    data_import.import_file.attach(io: StringIO.new("just,one\n"), filename: 'c.csv', content_type: 'text/csv')

    mailer_double = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
    expect(AdministratorNotifications::AccountNotificationMailer).not_to receive(:with)

    described_class.new.perform(data_import)
    expect(data_import.reload.status).to eq('failed')
  end
end
