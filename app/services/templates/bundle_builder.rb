# frozen_string_literal: true

require 'zip'
require 'stringio'

module Templates
  # Writes a template bundle as an in-memory ZIP (StringIO).
  # Caller is responsible for streaming it to the response or storing it.
  class BundleBuilder
    SERIALIZER_MAP = {
      'pipelines' => CategorySerializers::PipelinesSerializer,
      'agents' => CategorySerializers::AgentsSerializer,
      'teams' => CategorySerializers::TeamsSerializer,
      'labels' => CategorySerializers::LabelsSerializer,
      'custom_attributes' => CategorySerializers::CustomAttributesSerializer,
      'canned_responses' => CategorySerializers::CannedResponsesSerializer,
      'macros' => CategorySerializers::MacrosSerializer,
      'inboxes' => CategorySerializers::InboxesSerializer,
      'message_templates' => CategorySerializers::MessageTemplatesSerializer
    }.freeze

    MODEL_MAP = {
      'pipelines' => ::Pipeline,
      'agents' => ::AgentBot,
      'teams' => ::Team,
      'labels' => ::Label,
      'custom_attributes' => ::CustomAttributeDefinition,
      'canned_responses' => ::CannedResponse,
      'macros' => ::Macro,
      'inboxes' => ::Inbox,
      'message_templates' => ::MessageTemplate
    }.freeze

    def initialize(selection:, template_name:, description:, author:)
      @selection = selection || {}
      @template_name = template_name.to_s.strip
      @description = description.to_s
      @author = author.to_s
    end

    # @return [StringIO]
    def build
      contents = {}
      buffer = Zip::OutputStream.write_buffer do |zip|
        Schema::CATEGORIES.each do |category|
          ids = ids_for(category)
          next if ids.blank?

          records = base_relation(category).where(id: ids)
          payload = SERIALIZER_MAP[category].serialize_all(records)

          zip.put_next_entry("#{category}.json")
          zip.write(JSON.pretty_generate(payload))

          contents[category] = {
            'count' => payload.size,
            'items' => payload.map { |item| item['slug'] }
          }
        end

        manifest = Schema.manifest_skeleton(
          name: @template_name,
          description: @description,
          author: @author,
          contents: contents
        )
        zip.put_next_entry('manifest.json')
        zip.write(JSON.pretty_generate(manifest))
      end

      buffer.rewind
      buffer
    end

    def filename
      base = Templates::IdRemapper.slug_for(@template_name).presence || 'template'
      "#{base}#{Schema::BUNDLE_EXTENSION}"
    end

    private

    # Returns array of IDs to include for a given category, based on selection.
    # Selection format:
    #   { 'labels' => { 'all' => true } }                  # all
    #   { 'labels' => { 'ids' => ['uuid1', 'uuid2'] } }    # specific
    #   omitted or { 'all' => false, 'ids' => [] }         # none
    def ids_for(category)
      entry = @selection[category] || @selection[category.to_sym]
      return [] unless entry.is_a?(Hash)

      if entry['all'] || entry[:all]
        base_relation(category).pluck(:id)
      else
        Array(entry['ids'] || entry[:ids])
      end
    end

    # CRM-205: macros carry per-user personal visibility; every other category is
    # account-wide. Scope macros to the exporter's own personal + globals so a bundle
    # can never read another user's personal macro (the same leak CRM-195 closed on
    # the member actions) — whether the macro is pulled via `all` or requested by an
    # explicit id crafted from a leaked UUID. Current.user is set by the
    # templates.export-gated request; fail closed to none for any non-request caller
    # so it never NoMethodErrors on nil.id. (with_visibility ignores its second arg.)
    def base_relation(category)
      return MODEL_MAP[category] unless category == 'macros'
      return ::Macro.none if Current.user.nil?

      ::Macro.with_visibility(Current.user, {})
    end
  end
end
