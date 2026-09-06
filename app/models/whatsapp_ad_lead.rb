# == Schema Information
#
# Table name: whatsapp_ad_leads
#
#  id              :uuid             not null, primary key
#  ad_name         :string
#  adset_name      :string
#  body            :text
#  campaign_name   :string
#  ctwaclid        :string
#  enriched        :boolean          default(FALSE), not null
#  enriched_at     :datetime
#  gclid           :string
#  headline        :string
#  media_type      :string
#  platform        :string           default("meta"), not null
#  raw_referral    :jsonb            not null
#  source_type     :string
#  source_url      :string
#  status          :string           default("novo"), not null
#  thumbnail_url   :string
#  utm_campaign    :string
#  utm_content     :string
#  utm_medium      :string
#  utm_source      :string
#  utm_term        :string
#  valor_venda     :decimal(12, 2)
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  ad_id           :string
#  adset_id        :string
#  campaign_id     :string
#  contact_id      :uuid             not null
#  conversation_id :uuid
#  message_id      :uuid
#  source_id       :string
#
# Indexes
#
#  index_whatsapp_ad_leads_on_campaign_id      (campaign_id)
#  index_whatsapp_ad_leads_on_contact_id       (contact_id)
#  index_whatsapp_ad_leads_on_conversation_id  (conversation_id)
#  index_whatsapp_ad_leads_on_created_at       (created_at)
#  index_whatsapp_ad_leads_on_ctwaclid         (ctwaclid)
#  index_whatsapp_ad_leads_on_enriched         (enriched)
#  index_whatsapp_ad_leads_on_message_id       (message_id)
#  index_whatsapp_ad_leads_on_platform         (platform)
#  index_whatsapp_ad_leads_on_status           (status)
#
# Foreign Keys
#
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (message_id => messages.id)
#
class WhatsappAdLead < ApplicationRecord
  belongs_to :contact
  belongs_to :conversation, optional: true
  belongs_to :message, optional: true

  validates :platform, presence: true

  scope :meta, -> { where(platform: 'meta') }
  scope :pending_enrichment, -> { where(enriched: false).where.not(source_id: nil) }
end
