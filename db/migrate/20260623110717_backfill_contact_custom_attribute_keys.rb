# Backfill contact custom_attributes keyed by attribute_display_name (written by
# the journey "Update Custom Attribute" node before EVO-1850) so they are keyed
# by the canonical attribute_key slug — matching the CRM contact UI/API/import
# and the journey Conditional read path ({{contact.customAttributes.<slug>}}).
class BackfillContactCustomAttributeKeys < ActiveRecord::Migration[7.1]
  # custom_attribute_definitions.attribute_model enum → contact_attribute.
  CONTACT_ATTRIBUTE_MODEL = 1

  class CustomAttributeDefinition < ActiveRecord::Base
    self.table_name = 'custom_attribute_definitions'
  end

  class Contact < ActiveRecord::Base
    self.table_name = 'contacts'
    # `contacts.type` is a contact_type_enum column, NOT Rails STI — disable the
    # inheritance lookup so find_each/create don't choke on "person"/"company".
    self.inheritance_column = :_type_disabled
  end

  def up
    unless table_exists?(:custom_attribute_definitions) && table_exists?(:contacts)
      say 'Required tables missing; skipping backfill', true
      return
    end

    remap = build_remap
    if remap.empty?
      say 'No display-name → attribute_key remappings needed; skipping', true
      return
    end

    say "Remapping #{remap.size} display-name key(s) to attribute_key slug(s)", true
    moved = 0
    skipped = 0
    contacts_touched = 0

    Contact.where.not(custom_attributes: nil).find_each(batch_size: 500) do |contact|
      attrs = contact.custom_attributes
      next unless attrs.is_a?(Hash) && attrs.any?

      matched = attrs.keys & remap.keys
      next if matched.empty?

      changed = false
      matched.each do |display_name|
        slug = remap[display_name]
        if attrs.key?(slug)
          # Collision: the canonical slug value already exists — never clobber it.
          say "  contact #{contact.id}: slug '#{slug}' already present; leaving '#{display_name}' untouched", true
          skipped += 1
          next
        end
        attrs[slug] = attrs.delete(display_name)
        moved += 1
        changed = true
      end

      next unless changed

      # update_column bypasses validations/updated_at AND the Wisper
      # custom_attributes diff publisher (Contact#publish_custom_attribute_changes),
      # so a bulk backfill does not emit an event storm.
      contact.update_column(:custom_attributes, attrs)
      contacts_touched += 1
    rescue StandardError => e
      say "  ✗ contact #{contact.id}: #{e.message}", true
    end

    say "Backfill complete: #{moved} key(s) moved across #{contacts_touched} contact(s), #{skipped} skipped (collision)", true
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          'Original display-name keys are not recoverable once remapped to attribute_key.'
  end

  private

  # Build { display_name => attribute_key } for contact attributes, dropping
  # anything ambiguous so we never guess a key (attribute_display_name has NO
  # DB uniqueness constraint — only (attribute_key, attribute_model) is unique):
  #  - display_name == attribute_key (already aligned, no-op)
  #  - a display_name mapping to >1 distinct attribute_key
  #  - a display_name that collides with some OTHER def's attribute_key
  def build_remap
    defs = CustomAttributeDefinition
           .where(attribute_model: CONTACT_ATTRIBUTE_MODEL)
           .pluck(:attribute_display_name, :attribute_key)

    all_keys = defs.map { |(_display_name, key)| key }.compact.to_set

    grouped = Hash.new { |hash, key| hash[key] = [] }
    defs.each do |(display_name, key)|
      next if display_name.blank? || key.blank?
      next if display_name == key

      grouped[display_name] << key
    end

    remap = {}
    grouped.each do |display_name, keys|
      uniq_keys = keys.uniq
      if uniq_keys.size > 1
        say "  ambiguous display name '#{display_name}' → #{uniq_keys.inspect}; skipping", true
        next
      end
      if all_keys.include?(display_name)
        say "  display name '#{display_name}' collides with another attribute_key; skipping", true
        next
      end
      remap[display_name] = uniq_keys.first
    end

    remap
  end
end
