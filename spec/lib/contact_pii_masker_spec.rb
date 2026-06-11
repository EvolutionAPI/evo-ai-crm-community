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
      allow(RuntimeConfig).to receive(:account).and_return(nil)
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

    # EVO-1551 round 2 (CB-2): ActionCable listeners reacting to inbound
    # messages run with Current.user = nil but broadcast to agent sockets.
    # Default to masking — the websocket frame is the leak vector the card
    # exists to close.
    it 'returns true when flag is on and there is no current user (safe default for jobs/listeners)' do
      Current.account = { 'settings' => { 'mask_contact_pii' => true } }
      Current.user = nil
      expect(described_class.should_mask?).to be(true)
    end

    it 'still returns false when flag is OFF and there is no current user' do
      Current.account = { 'settings' => { 'mask_contact_pii' => false } }
      Current.user = nil
      expect(described_class.should_mask?).to be(false)
    end
  end

  # EVO-1551 round 3 (CB-3 + CB-4): predicate used by account-wide broadcasts
  # whose audience includes agents regardless of who triggered the event.
  # Ignores Current.user on purpose — admin's `Current.user` is irrelevant
  # when the payload is delivered to agents on the same socket topic.
  describe '.account_flag_enabled?' do
    before { Current.reset }
    after  { Current.reset }

    it 'returns true when the flag is on, regardless of an admin Current.user' do
      Current.account = { 'settings' => { 'mask_contact_pii' => true } }
      Current.user = instance_double('User', administrator?: true)
      expect(described_class.account_flag_enabled?).to be(true)
    end

    it 'returns false when the flag is off' do
      Current.account = { 'settings' => { 'mask_contact_pii' => false } }
      Current.user = instance_double('User', administrator?: true)
      expect(described_class.account_flag_enabled?).to be(false)
    end

    it 'returns false when no account is bound' do
      Current.account = nil
      allow(RuntimeConfig).to receive(:account).and_return(nil)
      expect(described_class.account_flag_enabled?).to be(false)
    end

    # EVO-1551 round 4: workers / listeners / ActionCableBroadcastJob run on
    # threads where EvoAuthConcern never executed, so Current.account is nil.
    # The predicate must fall back to the persisted RuntimeConfig source — the
    # same one the HTTP concern reads at evo_auth_concern.rb:62 — otherwise
    # masking silently no-ops in every async egress path.
    it 'falls back to RuntimeConfig.account when Current.account is nil (worker / listener path)' do
      Current.account = nil
      allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => true } })
      expect(described_class.account_flag_enabled?).to be(true)
    end

    it 'falls back to RuntimeConfig.account when Current.account is a non-Hash value' do
      Current.account = 'something-not-a-hash'
      allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => true } })
      expect(described_class.account_flag_enabled?).to be(true)
    end

    it 'prefers Current.account over RuntimeConfig.account when both are present' do
      Current.account = { 'settings' => { 'mask_contact_pii' => true } }
      allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => false } })
      expect(described_class.account_flag_enabled?).to be(true)
    end
  end

  # EVO-1551 round 4: same fallback exercised through should_mask?, which is
  # the predicate used by per-request serializers. A worker that calls a
  # serializer (e.g. via mailers, exports) would otherwise leak too.
  describe '.should_mask? with RuntimeConfig fallback' do
    before { Current.reset }
    after  { Current.reset }

    it 'masks when Current.account is nil but RuntimeConfig flag is on, regardless of Current.user' do
      Current.account = nil
      Current.user = nil
      allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => true } })
      expect(described_class.should_mask?).to be(true)
    end
  end

  # EVO-1551 round 4 (H2): WebWidget pre-chat persists captured PII inside
  # `Message#content_attributes`. The scrubber must remove the PII-bearing
  # keys without touching the rest of the hash (csat replies, in_reply_to,
  # etc.) so the conversation UI keeps rendering.
  describe '.scrub_pii_content_attributes' do
    it 'returns the input unchanged when blank' do
      expect(described_class.scrub_pii_content_attributes(nil)).to be_nil
      expect(described_class.scrub_pii_content_attributes({})).to eq({})
    end

    it 'returns non-Hash inputs untouched' do
      expect(described_class.scrub_pii_content_attributes('not a hash')).to eq('not a hash')
    end

    it 'removes submitted_email and submitted_values (string keys)' do
      attrs = {
        'submitted_email' => 'lead@example.com',
        'submitted_values' => [{ 'name' => 'phone', 'value' => '+5511999998888' }],
        'in_reply_to' => 42
      }
      scrubbed = described_class.scrub_pii_content_attributes(attrs)
      expect(scrubbed).not_to have_key('submitted_email')
      expect(scrubbed).not_to have_key('submitted_values')
      expect(scrubbed['in_reply_to']).to eq(42)
    end

    it 'removes symbol-keyed variants too (Rails store accessors)' do
      attrs = { submitted_email: 'lead@example.com', items: %w[a b] }
      scrubbed = described_class.scrub_pii_content_attributes(attrs)
      expect(scrubbed).not_to have_key(:submitted_email)
      expect(scrubbed[:items]).to eq(%w[a b])
    end

    # Documenting the chosen tradeoff: when the form contains both csat and
    # pre-chat values, dropping submitted_values trades a CSAT preview
    # render for not leaking the captured phone/email. Survey responses
    # have a dedicated path (CsatSurveys::ResponseBuilder) that does not
    # depend on the inline serializer.
    it 'drops the whole submitted_values hash even when it mixes csat with PII' do
      attrs = {
        'submitted_values' => {
          'csat_survey_response' => { 'rating' => 5 },
          'phone' => '+5511999998888'
        }
      }
      expect(described_class.scrub_pii_content_attributes(attrs)).to eq({})
    end

    it 'does not mutate the input hash' do
      attrs = { 'submitted_email' => 'x@y.com', 'in_reply_to' => 1 }
      described_class.scrub_pii_content_attributes(attrs)
      expect(attrs).to have_key('submitted_email')
    end
  end
end
