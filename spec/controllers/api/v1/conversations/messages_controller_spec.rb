# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe Api::V1::Conversations::MessagesController do
    it 'has controller spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Api::V1::Conversations::MessagesController, type: :controller do
  let(:conversation) { instance_double(Conversation) }
  let(:message_record) { instance_double(Message, id: 7, status: current_status, reload: nil) }
  let(:current_status) { 'read' }

  before do
    controller.instance_variable_set(:@conversation, conversation)
    allow(conversation).to receive_message_chain(:messages, :find).and_return(message_record)
    allow(message_record).to receive(:reload).and_return(message_record)
  end

  # AC7: #update must respond 422 when the funnel rejects the
  # transition (e.g. read → delivered). Previously this path silently lied
  # with a 200 response despite no DB change.
  describe '#update — funnel rejection surfaces as 422' do
    before do
      allow(controller).to receive(:permitted_params).and_return(
        ActionController::Parameters.new(id: 7, status: 'delivered').permit(:id, :status, :external_error)
      )
    end

    it 'AC7: returns 422 with the from→to transition in details when the service rejects' do
      rejecting = instance_double(Messages::StatusUpdateService, perform: false)
      allow(Messages::StatusUpdateService).to receive(:new).and_return(rejecting)

      expect(controller).to receive(:error_response).with(
        ApiErrorCodes::VALIDATION_ERROR,
        'Invalid status transition',
        details: 'read → delivered',
        status: :unprocessable_entity
      )

      controller.send(:update)
    end

    context 'when the service accepts the transition (happy path)' do
      let(:current_status) { 'sent' }

      it 'AC7 happy path: serializes the message and responds success' do
        accepting = instance_double(Messages::StatusUpdateService, perform: true)
        allow(Messages::StatusUpdateService).to receive(:new).and_return(accepting)
        allow(MessageSerializer).to receive(:serialize).and_return({})

        expect(controller).to receive(:success_response)
        controller.send(:update)
      end
    end
  end

  # AC8: #retry must NOT publish a redundant sent → sent Wisper
  # event. Previously the controller called StatusUpdateService.perform on
  # the freshly reset record (status now 'sent'), which produced a no-op
  # Wisper publish that the EvoFlow listener could not map.
  describe '#retry — no redundant Wisper publish' do
    before do
      allow(controller).to receive(:permitted_params).and_return(
        ActionController::Parameters.new(id: 7).permit(:id)
      )
      allow(message_record).to receive(:update!)
      allow(SendReplyJob).to receive(:perform_now)
      allow(MessageSerializer).to receive(:serialize).and_return({})
      allow(controller).to receive(:success_response)
    end

    it 'AC8: resets to :sent and enqueues SendReplyJob WITHOUT invoking StatusUpdateService' do
      expect(message_record).to receive(:update!).with(status: :sent, content_attributes: {})
      expect(SendReplyJob).to receive(:perform_now).with(7)
      expect(Messages::StatusUpdateService).not_to receive(:new)

      controller.send(:retry)
    end
  end
end
