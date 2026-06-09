# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContactPiiMasker do
  describe '.mask_phone' do
    it 'returns nil for blank input' do
      expect(described_class.mask_phone(nil)).to be_nil
      expect(described_class.mask_phone('')).to be_nil
      expect(described_class.mask_phone('abc')).to be_nil
    end

    it 'preserves DDI + DDD + last 4 for BR mobile formatted input' do
      expect(described_class.mask_phone('+55 11 99999-9999')).to eq('+55 11 ****-9999')
    end

    it 'preserves DDD + last 4 for parenthesised BR input' do
      expect(described_class.mask_phone('(11) 99999-9999')).to eq('(11) ****-9999')
    end

    it 'falls back to last-4 rule for international raw input' do
      expect(described_class.mask_phone('12155551234')).to eq('*******1234')
      expect(described_class.mask_phone('+12155551234')).to eq('+*******1234')
    end

    it 'masks every digit when fewer than 4 digits present' do
      expect(described_class.mask_phone('123')).to eq('***')
    end
  end

  describe '.mask_email' do
    it 'returns nil for blank input' do
      expect(described_class.mask_email(nil)).to be_nil
      expect(described_class.mask_email('')).to be_nil
    end

    it 'masks regular email keeping first letter + domain' do
      expect(described_class.mask_email('marcelo@gmail.com')).to eq('m***@gmail.com')
    end

    it 'hides length by always using 3 stars in local part' do
      expect(described_class.mask_email('marcelogorutubajr@gmail.com')).to eq('m***@gmail.com')
    end

    it 'returns *** for input without @' do
      expect(described_class.mask_email('no-arroba')).to eq('***')
    end
  end

  describe '.mask_identifier' do
    it 'returns nil for blank input' do
      expect(described_class.mask_identifier(nil)).to be_nil
    end

    it 'masks a WhatsApp JID keeping the suffix intact' do
      expect(described_class.mask_identifier('5511999999999@s.whatsapp.net'))
        .to eq('*********9999@s.whatsapp.net')
    end

    it 'returns *** when there are no digits and no @' do
      expect(described_class.mask_identifier('random-text-no-digits')).to eq('***')
    end
  end

  describe '.mask_phone_like_name' do
    it 'preserves alphabetic names untouched' do
      expect(described_class.mask_phone_like_name('Marcelo')).to eq('Marcelo')
      expect(described_class.mask_phone_like_name('💖')).to eq('💖')
      expect(described_class.mask_phone_like_name('Davi 123')).to eq('Davi 123')
    end

    it 'preserves blank input' do
      expect(described_class.mask_phone_like_name(nil)).to be_nil
      expect(described_class.mask_phone_like_name('')).to eq('')
    end

    it 'preserves short numeric strings (no leak risk)' do
      expect(described_class.mask_phone_like_name('1234567')).to eq('1234567')
    end

    it 'masks names that look like raw phone numbers (8+ digits, no letters)' do
      expect(described_class.mask_phone_like_name('553140204020')).to eq('********4020')
      expect(described_class.mask_phone_like_name('+5531982389112')).to eq('+*********9112')
    end
  end

  describe '.should_mask?' do
    before do
      Current.reset
    end

    after { Current.reset }

    let(:non_admin_user) do
      instance_double('User', administrator?: false)
    end

    let(:admin_user) do
      instance_double('User', administrator?: true)
    end

    it 'returns false when no account is bound' do
      Current.account = nil
      Current.user = non_admin_user
      expect(described_class.should_mask?).to be(false)
    end

    it 'returns false when flag is not enabled' do
      Current.account = { 'settings' => {} }
      Current.user = non_admin_user
      expect(described_class.should_mask?).to be(false)
    end

    it 'returns false when flag is on but user is admin' do
      Current.account = { 'settings' => { 'mask_contact_pii' => true } }
      Current.user = admin_user
      expect(described_class.should_mask?).to be(false)
    end

    it 'returns true when flag is on and user is non-admin' do
      Current.account = { 'settings' => { 'mask_contact_pii' => true } }
      Current.user = non_admin_user
      expect(described_class.should_mask?).to be(true)
    end

    it 'returns false when there is no current user (service token / system)' do
      Current.account = { 'settings' => { 'mask_contact_pii' => true } }
      Current.user = nil
      expect(described_class.should_mask?).to be(false)
    end
  end
end
