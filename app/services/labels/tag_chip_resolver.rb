# frozen_string_literal: true

# Turns a conversation tag into the chip a screen renders: { id, title, color }.
# The one semantics the REST and realtime read paths must agree on — title
# matches case-insensitively, id matches exactly (Postgres renders uuid
# lower-case, so an upper-case id is not a match), a tag with no match is
# dropped, and a label reached twice in the same tag list (by title and by id)
# is one chip, not two.
#
# Index-building strategy is deliberately left to the caller: a conversation
# list wants every Label loaded once (`Label.all`), a single realtime
# broadcast wants a query scoped to just its own tags. Both shapes feed
# #indexes_for the same way.
module Labels
  module TagChipResolver
    extend self

    DEFAULT_COLOR = '#1f93ff'

    # @param labels [Enumerable<Label>] candidate labels, already loaded
    # @return [Hash] { by_title: { downcased_title => Label }, by_id: { id_string => Label } }
    def indexes_for(labels)
      by_title = {}
      by_id = {}
      labels.each do |label|
        by_title[label.title.to_s.downcase] = label
        by_id[label.id.to_s] = label
      end
      { by_title: by_title, by_id: by_id }
    end

    # @param tags [Enumerable<String>] the tag list off the tagged record
    # @return [Array<Hash>] chips, deduplicated by label id
    def chips_for(tags, by_title:, by_id:)
      chips = Array(tags).map(&:to_s).filter_map do |tag|
        label = by_title[tag.downcase] || by_id[tag]
        next if label.nil?

        { id: label.id, title: label.title, color: label.color.presence || DEFAULT_COLOR }
      end
      chips.uniq { |chip| chip[:id] }
    end
  end
end
