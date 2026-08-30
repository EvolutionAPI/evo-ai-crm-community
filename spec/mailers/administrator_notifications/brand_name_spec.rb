require 'rails_helper'

RSpec.describe 'administrator notification e-mails use BRAND_NAME', type: :mailer do
  # Account is a module in this codebase, so a verifying double is not available.
  let(:account) do
    double('account', name: 'Acme Corp', custom_attributes: { 'marked_for_deletion_at' => Time.current.iso8601 }) # rubocop:disable RSpec/VerifiedDoubles
  end

  before do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('MAILER_TYPE', nil).and_return('smtp')
    allow(User).to receive(:joins).with(:roles).and_return(double(where: double(pluck: ['admin@example.com']))) # rubocop:disable RSpec/VerifiedDoubles
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with('BRAND_NAME', 'BRAND_URL')
                                        .and_return('BRAND_NAME' => 'Acme Agency', 'BRAND_URL' => 'https://acme.test')
    allow(GlobalConfig).to receive(:get).with('EVOLUTION_INSTANCE_ADMIN_EMAIL')
                                        .and_return('EVOLUTION_INSTANCE_ADMIN_EMAIL' => 'compliance@example.com')
  end

  it 'signs the account deletion notice with the configured brand' do
    mail = AdministratorNotifications::AccountNotificationMailer.account_deletion(account).deliver_now

    expect(mail.body.encoded).to include('Acme Agency Team')
    expect(mail.body.encoded).not_to match(/Evolution/)
  end

  it 'refers to the configured brand in the compliance notice' do
    mail = AdministratorNotifications::AccountComplianceMailer.with(soft_deleted_users: [])
                                                              .account_deleted(account).deliver_now

    expect(mail.body.encoded).to include('Acme Agency Installation')
    expect(mail.body.encoded).to include('Acme Agency System')
    expect(mail.body.encoded).not_to match(/Evolution/)
  end

  it 'falls back to a bare address when MAILER_SENDER_EMAIL is unset' do
    allow(GlobalConfigService).to receive(:load).with('MAILER_SENDER_EMAIL', nil).and_return(nil)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('MAILER_SENDER_EMAIL', ApplicationMailer::DEFAULT_SENDER_EMAIL)
                                 .and_return(ApplicationMailer::DEFAULT_SENDER_EMAIL)

    expect(ApplicationMailer.get_mailer_sender_email).to eq('accounts@evoai.app')
  end
end
