# frozen_string_literal: true

# Turns the tokens a caller sends into the titles `acts_as_taggable_on` stores.
#
# Callers express a label either by id (what the label pickers submit) or by
# title (what older rules and direct API callers still carry), so both shapes
# have to survive the trip. An id that no longer resolves to a Label row is
# preserved as a literal rather than dropped: dropping it turns "tag with this"
# into "tag with nothing" while the caller still reads success, which is how an
# add-label node came to answer 200 having tagged nothing.
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

      titles_by_id = Label.where(id: uuids).pluck(:id, :title).to_h.transform_keys(&:to_s)
      values.map { |value| titles_by_id[value] || value }.uniq
    end
  end
end
