# frozen_string_literal: true

module Whatsapp
  module Providers
    module Concerns
      module TemplateSync
        extend ActiveSupport::Concern

        def sync_template_to_database(template_data)
          content = extract_template_content(template_data)

          template = MessageTemplate.find_or_initialize_by(
            channel: whatsapp_channel,
            name: template_data['name'],
            language: template_data['language'] || 'pt_BR'
          )

          attrs = {
            content: content,
            category: template_data['category'],
            template_type: determine_template_type(template_data),
            components: extract_components_hash(template_data),
            variables: extract_template_variables(template_data),
            settings: {
              'status' => template_data['status'],
              'quality_score' => template_data['quality_score'],
              'source' => template_data['source']
            }.compact,
            metadata: {
              'external_id' => template_data['id'],
              'namespace' => template_data['namespace'],
              'rejected_reason' => template_data['rejected_reason']
            }.compact
          }

          # The `active` column is a user-controlled toggle (show/hide in
          # pickers), not a mirror of Meta approval. Keep it separate:
          # - On first sync (new record), default to true so the template
          #   shows up in the management table with a real "pending" badge
          #   instead of being silently hidden.
          # - On subsequent syncs, preserve whatever the user set.
          attrs[:active] = true if template.new_record?

          template.assign_attributes(attrs)
          template.save!
        rescue StandardError => e
          Rails.logger.error "Error syncing template #{template_data['name']}: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
        end

        def extract_template_content(template_data)
          return template_data['content'] if template_data['content'].present?
          return template_data['text'] if template_data['text'].present?
          return template_data['bodyText'] if template_data['bodyText'].present?
          
          if template_data['components']&.is_a?(Array)
            body_component = template_data['components'].find { |c| c['type'] == 'BODY' }
            return body_component['text'] if body_component&.dig('text')
          end
          
          'Template content'
        end

        def extract_components_hash(template_data)
          return {} unless template_data['components'].is_a?(Array)
          
          components = {}
          template_data['components'].each do |component|
            type = component['type']&.downcase
            components[type] = component if type
          end
          components
        end

        def extract_template_variables(template_data)
          variables = []
          
          return variables unless template_data['components']&.is_a?(Array)
          
          template_data['components'].each do |component|
            next unless component['parameters']&.is_a?(Array)
            
            component['parameters'].each_with_index do |param, index|
              variables << {
                'name' => "var_#{index + 1}",
                'type' => param['type'] || 'text',
                'required' => false
              }
            end
          end
          
          variables
        end

        def determine_template_type(template_data)
          return 'text' unless template_data['components']&.is_a?(Array)
          
          has_media = template_data['components'].any? do |c|
            c['type'] == 'HEADER' && c['format']&.in?(%w[IMAGE VIDEO DOCUMENT AUDIO])
          end
          has_buttons = template_data['components'].any? { |c| c['type'] == 'BUTTONS' }
          
          return 'interactive' if has_buttons
          return 'media' if has_media
          
          'text'
        end
      end
    end
  end
end
