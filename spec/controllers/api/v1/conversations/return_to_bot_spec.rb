# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe Api::V1::ConversationsController do
    it 'has controller spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

# EVO-1680 — POST /api/v1/.../conversations/:id/return_to_bot exposes the
# reverse human→bot handoff. Covers happy path (200), domain validation
# failures (422), and the RBAC gate inherited via require_permissions.
RSpec.describe Api::V1::ConversationsController, type: :controller do
  describe '#return_to_bot' do
    let(:user) { instance_double(User, role: 'agent') }
    let(:conversation) { instance_double(Conversation) }
    let(:serialized_payload) { { 'id' => 42, 'status' => 'pending' } }

    before do
      allow(Current).to receive(:user).and_return(user)
      allow(controller).to receive(:conversation).and_return(true) # before_action no-op
      controller.instance_variable_set(:@conversation, conversation)
      allow(controller).to receive(:check_return_to_bot_permission!).and_return(true)
      allow(ConversationSerializer).to receive(:serialize)
        .with(conversation, include_messages: false)
        .and_return(serialized_payload)
    end

    context 'happy path' do
      before { allow(conversation).to receive(:return_to_bot!).and_return(true) }

      it 'invokes return_to_bot! on the conversation' do
        expect(conversation).to receive(:return_to_bot!)
        allow(controller).to receive(:success_response)
        controller.send(:return_to_bot)
      end

      it 'responds with the serialized conversation payload' do
        expect(controller).to receive(:success_response).with(
          hash_including(data: serialized_payload, message: 'Conversation returned to bot successfully')
        )
        controller.send(:return_to_bot)
      end
    end

    context 'when the inbox has no agent bot' do
      before do
        allow(conversation).to receive(:return_to_bot!)
          .and_raise(Conversations::InvalidHandoffError, 'inbox has no agent bot connected')
      end

      it 'responds with 422 and the validation error message' do
        expect(controller).to receive(:error_response).with(
          ApiErrorCodes::VALIDATION_ERROR,
          'inbox has no agent bot connected',
          status: :unprocessable_entity
        )
        controller.send(:return_to_bot)
      end
    end

    context 'when conversation status is not open' do
      before do
        allow(conversation).to receive(:return_to_bot!)
          .and_raise(Conversations::InvalidHandoffError, 'conversation must be open')
      end

      it 'responds with 422 and the validation error message' do
        expect(controller).to receive(:error_response).with(
          ApiErrorCodes::VALIDATION_ERROR,
          'conversation must be open',
          status: :unprocessable_entity
        )
        controller.send(:return_to_bot)
      end
    end

    context 'when an untyped error bubbles up' do
      before do
        allow(conversation).to receive(:return_to_bot!).and_raise(StandardError, 'db is on fire')
      end

      it 'does NOT swallow the error as 422 (rescue is typed)' do
        expect { controller.send(:return_to_bot) }.to raise_error(StandardError, 'db is on fire')
      end
    end
  end

  describe 'permission gate wiring' do
    # EvoPermissionConcern#require_permissions defines `check_<action>_permission!`
    # via define_method (see app/controllers/concerns/evo_permission_concern.rb).
    # If the action is missing from the require_permissions mapping, the method
    # is absent — this spec fails the moment the gate is removed.
    it 'installs check_return_to_bot_permission! via require_permissions' do
      expect(described_class.private_instance_methods).to include(:check_return_to_bot_permission!)
    end

    it 'invokes check_permission! with the conversations.toggle_status key' do
      controller_instance = described_class.new
      expect(controller_instance).to receive(:check_permission!).with('conversations.toggle_status', :user)
      controller_instance.send(:check_return_to_bot_permission!)
    end
  end
end
