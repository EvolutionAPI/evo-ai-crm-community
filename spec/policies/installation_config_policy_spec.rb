require 'rails_helper'

RSpec.describe InstallationConfigPolicy, type: :policy do
  let(:record) { :installation_config }

  def policy_for(user)
    described_class.new({ user: user, account: nil }, record)
  end

  describe '#manage?' do
    context 'when user holds the installation_configs.manage grant' do
      let(:user) { instance_double('User', administrator?: false) }

      before do
        allow(user).to receive(:has_permission?).with('installation_configs.manage').and_return(true)
      end

      it 'returns true' do
        expect(policy_for(user).manage?).to be true
      end
    end

    context 'when user is an administrator without the grant' do
      let(:user) { instance_double('User', administrator?: true) }

      before do
        allow(user).to receive(:has_permission?).with('installation_configs.manage').and_return(false)
      end

      it 'returns false' do
        expect(policy_for(user).manage?).to be false
      end
    end

    context 'when user is neither administrator nor granted' do
      let(:user) { instance_double('User', administrator?: false) }

      before do
        allow(user).to receive(:has_permission?).with('installation_configs.manage').and_return(false)
      end

      it 'returns false' do
        expect(policy_for(user).manage?).to be false
      end
    end

    context 'when user is nil' do
      it 'returns false' do
        expect(policy_for(nil).manage?).to be false
      end
    end
  end

  describe 'CRUD methods delegate to manage?' do
    let(:user) { instance_double('User', administrator?: false) }

    before do
      allow(user).to receive(:has_permission?).with('installation_configs.manage').and_return(true)
    end

    %i[index? show? create? update? destroy?].each do |method|
      it "#{method} delegates to manage?" do
        policy = policy_for(user)
        expect(policy.send(method)).to eq(policy.manage?)
      end
    end
  end
end
