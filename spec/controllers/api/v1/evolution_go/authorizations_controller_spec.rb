# frozen_string_literal: true

require 'rails_helper'

# Unit-level coverage for the eager webhook subscription added on Evolution Go
# instance creation. The /instance/connect call is what registers the CRM as
# webhook receiver in Evolution Go — running it right after /instance/create
# means messages from the connected device flow even before the user opens the
# QR screen. A failure here MUST NOT regress the create response, since the
# QR flow re-runs the same call later and would retry the registration.
RSpec.describe Api::V1::EvolutionGo::AuthorizationsController, type: :controller do
  describe '#register_webhook_after_create' do
    let(:controller_instance) { described_class.new }
    let(:api_url) { 'http://evo.example.com' }
    let(:instance_token) { 'instance-token-123' }

    it 'invokes connect_instance with the freshly created instance credentials and short timeouts' do
      expect(controller_instance).to receive(:connect_instance).with(api_url, instance_token, nil, open_timeout: 5, read_timeout: 5)

      controller_instance.send(:register_webhook_after_create, api_url, instance_token)
    end

    it 'swallows errors raised by connect_instance and logs them at warn level' do
      allow(controller_instance).to receive(:connect_instance).and_raise(StandardError.new('BACKEND_URL is not configured'))
      expect(Rails.logger).to receive(:warn).with(/Eager webhook registration failed/)

      expect do
        controller_instance.send(:register_webhook_after_create, api_url, instance_token)
      end.not_to raise_error
    end

    it 'skips the call entirely when api_url is blank' do
      expect(controller_instance).not_to receive(:connect_instance)

      controller_instance.send(:register_webhook_after_create, '', instance_token)
    end

    it 'skips the call entirely when instance_token is blank' do
      expect(controller_instance).not_to receive(:connect_instance)

      controller_instance.send(:register_webhook_after_create, api_url, nil)
    end
  end

  # Pins the wire-up: a refactor that drops the register_webhook_after_create
  # call from #create would silently regress EVO-984 (instance has no webhook
  # until QR is opened) and the unit test above would still pass.
  describe '#create wiring' do
    let(:controller_instance) { described_class.new }

    before do
      controller_instance.params = ActionController::Parameters.new(
        authorization: { mode: 'create', api_url: 'http://evo.example.com', admin_token: 'admin-tok', instance_name: 'inst-name' }
      )
      controller_instance.instance_variable_set(:@api_url, 'http://evo.example.com')
      controller_instance.instance_variable_set(:@admin_token, 'admin-tok')
      controller_instance.instance_variable_set(:@instance_name, 'inst-name')

      allow(controller_instance).to receive(:create_instance_go).and_return(
        'instance_token' => 'tok-from-create',
        'instance_uuid' => 'uuid-from-create',
        'data' => {}
      )
      allow(controller_instance).to receive(:render)
    end

    it 'invokes register_webhook_after_create with the freshly created instance_token' do
      expect(controller_instance).to receive(:register_webhook_after_create).with('http://evo.example.com', 'tok-from-create')

      controller_instance.create
    end

    # Invariante declarado no PR: "Failures are swallowed so a transient webhook
    # error does not regress channel creation". Sem este teste, alguém remove o
    # rescue de register_webhook_after_create e o invariante quebra silencioso.
    it 'still renders success when the eager webhook registration fails' do
      allow(controller_instance).to receive(:connect_instance).and_raise(StandardError.new('boom'))

      expect(controller_instance).to receive(:render).with(
        hash_including(json: hash_including(success: true, instance_token: 'tok-from-create'))
      )

      expect { controller_instance.create }.not_to raise_error
    end
  end

  describe '#fetch connection status' do
    let(:controller_instance) { described_class.new }
    let(:channel) do
      instance_double(
        Channel::Whatsapp,
        id: 'channel-id',
        provider_connection: { 'connection' => 'open', 'error' => nil },
        reauthorization_required?: false
      )
    end
    let(:inbox) { instance_double(Inbox, channel: channel) }

    before do
      controller_instance.instance_variable_set(:@api_url, 'http://evo.example.com')
      controller_instance.instance_variable_set(:@admin_token, 'admin-token')
      controller_instance.instance_variable_set(:@instance_uuid, 'instance-uuid')
      controller_instance.instance_variable_set(:@inbox, inbox)
    end

    it 'accepts a string true returned by Evolution Go as connected' do
      allow(controller_instance).to receive(:fetch_instance_info).and_return('connected' => 'true')
      expect(channel).to receive(:update_provider_connection!).with('connection' => 'open', 'error' => nil)
      expect(controller_instance).to receive(:render).with(
        hash_including(json: hash_including(data: hash_including(instance: hash_including(state: 'open', connected: true))))
      )

      controller_instance.fetch
    end

    it 'does not overwrite an open event snapshot when the polling response has no connection field' do
      allow(controller_instance).to receive(:fetch_instance_info).and_return('jid' => '5511999999999@s.whatsapp.net')
      expect(channel).not_to receive(:update_provider_connection!)
      expect(controller_instance).to receive(:render).with(
        hash_including(json: hash_including(data: hash_including(instance: hash_including(state: 'open', connected: true))))
      )

      controller_instance.fetch
    end
  end
end
