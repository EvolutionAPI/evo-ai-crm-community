class CreateWhatsappAdLeads < ActiveRecord::Migration[7.1]
  def change
    return if table_exists?(:whatsapp_ad_leads)

    create_table :whatsapp_ad_leads, id: :uuid, if_not_exists: true do |t|
      t.references :contact, null: false, foreign_key: true, type: :uuid
      t.references :conversation, foreign_key: true, type: :uuid
      t.references :message, foreign_key: true, type: :uuid

      # Click-to-WhatsApp attribution (from the message's externalAdReplyInfo/
      # referral, captured by Whatsapp::EvolutionHandlers::ContentHandlers).
      t.string :platform, null: false, default: 'meta' # 'meta' | 'google' | 'direct'
      t.string :ctwaclid
      t.string :gclid
      t.string :source_id # ad id inside the referral payload
      t.string :source_url
      t.string :source_type
      t.string :headline
      t.text :body
      t.string :media_type
      t.string :thumbnail_url

      # Filled in later by the enrichment job (Meta Marketing API lookup by
      # ad id) — nil until enriched.
      t.string :campaign_id
      t.string :campaign_name
      t.string :adset_id
      t.string :adset_name
      t.string :ad_id
      t.string :ad_name

      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign
      t.string :utm_term
      t.string :utm_content

      t.string :status, null: false, default: 'novo' # 'novo' | 'em_atendimento' | 'convertido' | 'perdido'
      t.decimal :valor_venda, precision: 12, scale: 2

      t.boolean :enriched, null: false, default: false
      t.datetime :enriched_at
      t.jsonb :raw_referral, null: false, default: {}

      t.timestamps
    end

    add_index :whatsapp_ad_leads, :ctwaclid, if_not_exists: true unless index_exists?(:whatsapp_ad_leads, :ctwaclid)
    add_index :whatsapp_ad_leads, :platform, if_not_exists: true unless index_exists?(:whatsapp_ad_leads, :platform)
    add_index :whatsapp_ad_leads, :status, if_not_exists: true unless index_exists?(:whatsapp_ad_leads, :status)
    add_index :whatsapp_ad_leads, :campaign_id, if_not_exists: true unless index_exists?(:whatsapp_ad_leads, :campaign_id)
    add_index :whatsapp_ad_leads, :created_at, if_not_exists: true unless index_exists?(:whatsapp_ad_leads, :created_at)
    unless index_exists?(:whatsapp_ad_leads, :enriched)
      add_index :whatsapp_ad_leads, :enriched, if_not_exists: true
    end
  end
end
