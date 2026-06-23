class DataImport::ConversationManager
  REQUIRED_COLUMNS = %w[conversation_external_id contact_identifier message_content direction sent_at].freeze
  VALID_DIRECTIONS = %w[incoming outgoing].freeze
  IMPORTED_HISTORY_INBOX_NAME = 'Imported History'.freeze
  MAX_ERRORS_PERSISTED = 1000

  attr_reader :report

  def initialize(data_import)
    @data_import = data_import
    @report = { 'total_rows' => 0, 'success_count' => 0, 'error_count' => 0, 'errors' => [] }
    @rejected_rows = []
    @csv_headers = nil
    # Conversation id => max sent_at seen across imported rows. Used to set
    # last_activity_at to the historical max instead of the wall-clock time
    # of the import job (otherwise an imported 2024 conversation sorts to
    # the top of the inbox as if it were active now).
    @conversation_last_activity = {}
  end

  def process
    raw_csv = @data_import.import_file.download.force_encoding('UTF-8')
    raw_csv = raw_csv.encode('UTF-16le', invalid: :replace, replace: '').encode('UTF-8') unless raw_csv.valid_encoding?

    csv = CSV.parse(raw_csv, headers: true)
    @csv_headers = csv.headers
    validate_headers!(@csv_headers)

    # Disable belongs_to :conversation, touch: true for the duration of the
    # import. On a 50k-row CSV that saves ~50k redundant UPDATEs against
    # conversations (last_activity_at is set explicitly in
    # `resolve_touched_conversations` from the historical max sent_at).
    ActiveRecord::Base.no_touching do
      csv.each_with_index do |row, index|
        @report['total_rows'] += 1
        params = row.to_h.with_indifferent_access
        row_no = row_number(index)
        begin
          ActiveRecord::Base.transaction(requires_new: true) do
            import_row(params, row_no)
          end
          @report['success_count'] += 1
        rescue RowError => e
          Rails.logger.warn "[DataImport::Conversation] row #{row_no} failed: #{e.message}"
          record_failure(row, row_no, e.message)
        rescue ActiveRecord::RecordInvalid => e
          message = "validation failed: #{e.record.errors.full_messages.join(', ')}"
          Rails.logger.warn "[DataImport::Conversation] row #{row_no} failed: #{message}"
          record_failure(row, row_no, message)
        rescue ActiveRecord::RecordNotUnique => e
          message = "uniqueness violation: #{e.message.lines.first&.strip}"
          Rails.logger.warn "[DataImport::Conversation] row #{row_no} failed: #{message}"
          record_failure(row, row_no, message)
        rescue ActiveRecord::StatementInvalid => e
          message = "statement invalid: #{e.message.lines.first&.strip}"
          Rails.logger.warn "[DataImport::Conversation] row #{row_no} failed: #{message}"
          record_failure(row, row_no, message)
        end
      end
    end

    resolve_touched_conversations

    @report
  end

  def resolve_touched_conversations
    return if @conversation_last_activity.empty?

    Conversation.where(id: @conversation_last_activity.keys)
                .update_all(status: Conversation.statuses[:resolved])

    # Imported conversations should sort by their historical max sent_at, not
    # by the wall-clock time of the import (the column default is
    # CURRENT_TIMESTAMP). Force-set, do not GREATEST: GREATEST against the
    # default would pin the row to "now" and re-introduce the very problem
    # this fixes.
    @conversation_last_activity.each do |conversation_id, max_sent_at|
      Conversation.where(id: conversation_id).update_all(last_activity_at: max_sent_at)
    end
  end

  def rejected_rows
    @rejected_rows
  end

  def csv_headers
    @csv_headers
  end

  private

  class RowError < StandardError; end

  def row_number(index)
    index + 2
  end

  def validate_headers!(headers)
    missing = REQUIRED_COLUMNS - headers.to_a
    return if missing.empty?

    raise CSV::MalformedCSVError.new("missing required columns: #{missing.join(', ')}", 0)
  end

  def import_row(params, row_no)
    REQUIRED_COLUMNS.each do |col|
      raise RowError, "missing value for #{col}" if params[col].to_s.strip.empty?
    end

    direction = params[:direction].to_s.downcase
    raise RowError, "invalid direction '#{params[:direction]}'" unless VALID_DIRECTIONS.include?(direction)

    sent_at = parse_timestamp(params[:sent_at])
    raise RowError, "invalid sent_at '#{params[:sent_at]}'" if sent_at.nil?

    contact = find_contact(params[:contact_identifier])
    raise RowError, "contact not found for identifier '#{params[:contact_identifier]}'" if contact.nil?

    inbox = ensure_imported_history_inbox
    contact_inbox = ensure_contact_inbox(contact, inbox, params[:conversation_external_id])
    conversation = ensure_conversation(contact_inbox, params[:conversation_external_id])

    current_max = @conversation_last_activity[conversation.id]
    @conversation_last_activity[conversation.id] = sent_at if current_max.nil? || sent_at > current_max

    return if message_exists?(conversation, params[:message_external_id])

    create_message(conversation, params, direction, sent_at)
  end

  # Tolerant parser for `sent_at`. Supports ISO8601 (with/without offset),
  # space-separated SQL-style ("YYYY-MM-DD HH:MM:SS"), date-only, and
  # 10-/13-digit Unix epoch. Naive timestamps (no offset) are interpreted
  # as UTC, never server-local — keeps the imported timeline stable across
  # deploy regions.
  def parse_timestamp(value)
    raw = value.to_s.strip
    return nil if raw.empty?

    if raw =~ /\A\d{10}\z/
      Time.at(raw.to_i).utc
    elsif raw =~ /\A\d{13}\z/
      Time.at(raw.to_i / 1000.0).utc
    elsif raw.match?(/[zZ]|[+-]\d{2}:?\d{2}\z/)
      Time.find_zone('UTC').parse(raw)
    else
      Time.find_zone('UTC').parse(raw)
    end
  rescue ArgumentError, TypeError
    nil
  end

  def find_contact(identifier)
    value = identifier.to_s.strip
    return nil if value.empty?

    by_identifier = Contact.find_by(identifier: value)
    return by_identifier if by_identifier

    phone = format_phone(value)
    by_phone = phone && Contact.find_by(phone_number: phone)
    return by_phone if by_phone

    return nil unless value.include?('@')

    Contact.from_email(value)
  end

  def format_phone(value)
    cleaned = value.gsub(/\D/, '')
    return nil if cleaned.empty?

    "+#{cleaned}"
  end

  def ensure_imported_history_inbox
    @imported_history_inbox ||= Inbox.find_by(display_name: IMPORTED_HISTORY_INBOX_NAME, channel_type: 'Channel::Api') ||
                                Inbox.create!(name: IMPORTED_HISTORY_INBOX_NAME, channel: Channel::Api.create!)
  end

  def ensure_contact_inbox(contact, inbox, source_id)
    ContactInbox.find_or_create_by!(inbox_id: inbox.id, source_id: source_id) do |ci|
      ci.contact_id = contact.id
    end
  end

  def ensure_conversation(contact_inbox, external_id)
    Conversation.find_or_create_by!(identifier: external_id) do |c|
      c.contact_id = contact_inbox.contact_id
      c.inbox_id = contact_inbox.inbox_id
      c.contact_inbox_id = contact_inbox.id
      c.status = :resolved
      c.source = :imported
      c.send(:status_explicitly_set!)
      c.additional_attributes = { 'imported' => true, 'source' => 'data_import' }
    end
  end

  def message_exists?(conversation, external_id)
    return false if external_id.to_s.strip.empty?

    conversation.messages.exists?(source_id: external_id)
  end

  def create_message(conversation, params, direction, sent_at)
    content, content_attributes = build_message_content(params)
    content_attributes[:external_created_at] = sent_at.to_i
    content_attributes[:sender_name] = params[:sender_name] if params[:sender_name].present?

    conversation.messages.create!(
      inbox: conversation.inbox,
      content: content,
      message_type: direction == 'incoming' ? :incoming : :outgoing,
      private: false,
      source: :imported,
      source_id: params[:message_external_id].presence,
      content_attributes: content_attributes,
      created_at: sent_at,
      updated_at: sent_at
    )
  end

  def build_message_content(params)
    type = params[:message_type].to_s.strip
    return [params[:message_content].to_s, {}] if type.empty? || type.downcase == 'text'

    ["[mídia: #{type}]", { imported_media_type: type }]
  end

  def record_failure(row, row_no, reason)
    @report['error_count'] += 1
    if @report['errors'].length < MAX_ERRORS_PERSISTED
      @report['errors'] << { 'row' => row_no, 'reason' => reason }
    end
    failed = row.to_h
    failed['errors'] = reason
    failed['_row_number'] = row_no
    @rejected_rows << failed
  end
end
