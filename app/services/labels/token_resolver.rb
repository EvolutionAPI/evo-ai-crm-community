# frozen_string_literal: true

# Turns the tokens a caller sends into the titles `acts_as_taggable_on` stores.
#
# Callers express a label either by id (what the label pickers submit) or by
# title (what older rules and direct API callers still carry), so both shapes
# have to survive the trip. An id that no longer resolves to a Label row is
# preserved as a literal rather than dropped: dropping it turns "tag with this"
# into "tag with nothing" while the caller still reads success, which is how an
# add-label node came to answer 200 having tagged nothing.
#
# Labels::TagChipResolver is the read-side counterpart. It drops a tag it
# cannot match, because there an unmatched tag is one chip missing from a
# render; here the token is about to be persisted, so it is kept and logged.
# LabelActivityMessageHandler keeps a third copy on purpose — see the note
# there before folding it in.
module Labels
  module TokenResolver
    extend self

    UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    # @param tokens [Enumerable<String>, String] label ids and/or titles
    # @return [Array<String>] titles, in the order given, deduplicated
    def titles_for(tokens)
      values = Array(tokens).map(&:to_s).reject(&:empty?)
      uuids = values.grep(UUID_FORMAT)
      # No id to translate means no reason to touch the labels table.
      return values.uniq if uuids.empty?

      titles_by_id = titles_by_id_for(uuids)
      values.map { |value| titles_by_id[value.downcase] || value }.uniq
    end

    private

    # Keyed by the folded id: Postgres renders uuid lower-case, so an id typed
    # in upper case reaches a row through `where` but would miss a hash keyed
    # by what the row returned.
    def titles_by_id_for(uuids)
      titles_by_id = Label.where(id: uuids).pluck(:id, :title).to_h.transform_keys { |id| id.to_s.downcase }
      log_unresolved(uuids.reject { |id| titles_by_id.key?(id.downcase) })
      titles_by_id
    end

    # Keeping the token honours the caller's intent, but it also persists a
    # uuid-named tag — the very data `rake automation:cleanup_label_uuid_tags`
    # exists to sweep. Without this line the automation leaves no trace of it.
    def log_unresolved(ids)
      return if ids.empty?

      Rails.logger.warn("[Labels::TokenResolver] kept as literal tags, no Label resolves them: #{ids.join(', ')}")
    end
  end
end
