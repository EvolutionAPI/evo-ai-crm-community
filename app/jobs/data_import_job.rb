# TODO: logic is written tailored to contact import since its the only import available
# let's break this logic and clean this up in future

class DataImportJob < ApplicationJob
  queue_as :low
  retry_on ActiveStorage::FileNotFoundError, wait: 1.minute, attempts: 3

  def perform(data_import)
    @data_import = data_import
    Rails.logger.info "📊 DataImportJob: Starting import for data_import_id=#{@data_import.id} data_type=#{@data_import.data_type}"
    begin
      case @data_import.data_type
      when 'conversations'
        process_conversations_import
      else
        @contact_manager = DataImport::ContactManager.new
        process_import_file
        send_import_notification_to_admin
      end
      Rails.logger.info "📊 DataImportJob: Import completed for data_import_id=#{@data_import.id}"
    rescue CSV::MalformedCSVError => e
      Rails.logger.error "📊 DataImportJob: CSV error for data_import_id=#{@data_import.id}: #{e.message}"
      handle_csv_error(e)
    rescue => e
      Rails.logger.error "📊 DataImportJob: Unexpected error for data_import_id=#{@data_import.id}: #{e.class} - #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      raise
    end
  end

  private

  def process_conversations_import
    @data_import.update!(status: :processing)
    started_at = Time.current
    Rails.logger.info(
      "[DataImport::Conversation] start data_import_id=#{@data_import.id}"
    )

    manager = DataImport::ConversationManager.new(@data_import)
    report = manager.process

    @data_import.update!(
      status: :completed,
      total_records: report['total_rows'],
      processed_records: report['success_count'],
      processing_errors: report.to_json
    )

    duration = (Time.current - started_at).round(2)
    Rails.logger.info(
      "[DataImport::Conversation] done data_import_id=#{@data_import.id} " \
      "rows_total=#{report['total_rows']} imported=#{report['success_count']} " \
      "failed=#{report['error_count']} duration=#{duration}s"
    )

    save_conversations_failed_records(manager)
  end

  def save_conversations_failed_records(manager)
    rejected = manager.rejected_rows
    return if rejected.blank?

    headers = (manager.csv_headers || rejected.first.keys.reject { |k| k.start_with?('_') || k == 'errors' }) + ['errors']
    csv_data = CSVSafe.generate do |csv|
      csv << headers
      rejected.each do |record|
        csv << headers.map { |h| record[h] }
      end
    end

    @data_import.failed_records.attach(
      io: StringIO.new(csv_data),
      filename: "#{Time.zone.today.strftime('%Y%m%d')}_conversations_failed.csv",
      content_type: 'text/csv'
    )
  end

  def process_import_file
    @data_import.update!(status: :processing)
    Rails.logger.info "📊 DataImportJob: Processing file for data_import_id=#{@data_import.id}"

    # Separar contatos por tipo
    person_rows, company_rows, rejected_contacts = parse_csv_and_classify_contacts
    Rails.logger.info "📊 DataImportJob: Parsed CSV - persons: #{person_rows.length}, companies: #{company_rows.length}, rejected: #{rejected_contacts.length}"

    # Primeiro importar empresas (necessário para vínculos)
    import_companies(company_rows)

    # Depois importar pessoas
    import_persons(person_rows)

    # Processar vínculos entre pessoas e empresas
    process_company_linkages(person_rows)

    total_imported = company_rows.length + person_rows.length
    Rails.logger.info "📊 DataImportJob: Total to import: #{total_imported} (persons: #{person_rows.length}, companies: #{company_rows.length})"
    update_data_import_status(total_imported, rejected_contacts.length)
    save_failed_records_csv(rejected_contacts)
  end

  def parse_csv_and_classify_contacts
    person_rows = []
    company_rows = []
    rejected_contacts = []

    # Ensuring that importing non utf-8 characters will not throw error
    data = @data_import.import_file.download
    Rails.logger.info "📊 DataImportJob: Downloaded CSV file, size: #{data.size} bytes"
    utf8_data = data.force_encoding('UTF-8')

    # Ensure that the data is valid UTF-8, preserving valid characters
    clean_data = utf8_data.valid_encoding? ? utf8_data : utf8_data.encode('UTF-16le', invalid: :replace, replace: '').encode('UTF-8')

    csv = CSV.parse(clean_data, headers: true)
    Rails.logger.info "📊 DataImportJob: Parsed CSV, total rows: #{csv.count}"

    csv.each_with_index do |row, index|
      params = row.to_h.with_indifferent_access
      tipo = params[:tipo] || params[:type] || 'person'

      Rails.logger.debug "📊 DataImportJob: Row #{index + 1} - tipo=#{tipo}, name=#{params[:nome] || params[:name]}, phone=#{params[:telefone] || params[:phone_number]}"

      if tipo == 'company'
        current_contact = @contact_manager.build_contact(params)
        if current_contact.valid?
          company_rows << { row: params, contact: current_contact }
          Rails.logger.debug "📊 DataImportJob: Row #{index + 1} - COMPANY valid"
        else
          append_rejected_contact(row, current_contact, rejected_contacts)
          Rails.logger.warn "📊 DataImportJob: Row #{index + 1} - COMPANY invalid - errors: #{current_contact.errors.full_messages.join(', ')}"
        end
      else
        current_contact = @contact_manager.build_contact(params)
        if current_contact.valid?
          person_rows << { row: params, contact: current_contact }
          Rails.logger.debug "📊 DataImportJob: Row #{index + 1} - PERSON valid"
        else
          append_rejected_contact(row, current_contact, rejected_contacts)
          Rails.logger.warn "📊 DataImportJob: Row #{index + 1} - PERSON invalid - errors: #{current_contact.errors.full_messages.join(', ')}"
        end
      end
    end

    [person_rows, company_rows, rejected_contacts]
  end

  def append_rejected_contact(row, contact, rejected_contacts)
    row['errors'] = contact.errors.full_messages.join(', ')
    rejected_contacts << row
    Rails.logger.debug "📊 DataImportJob: Rejected contact - name: #{row[:nome] || row[:name]}, errors: #{row['errors']}"
  end

  def import_contacts(contacts)
    # <struct ActiveRecord::Import::Result failed_instances=[], num_inserts=1, ids=[444, 445], results=[]>
    result = Contact.import(contacts, synchronize: contacts, on_duplicate_key_ignore: true, track_validation_failures: true, validate: true, batch_size: 1000)
    Rails.logger.info "📊 DataImportJob: Import result - num_inserts: #{result.num_inserts}, failed_instances: #{result.failed_instances.size}"
    result
  end

  def import_companies(company_rows)
    return if company_rows.empty?
    Rails.logger.info "📊 DataImportJob: Importing #{company_rows.length} companies"

    companies = company_rows.map { |row_data| row_data[:contact] }
    result = Contact.import(companies, synchronize: companies, on_duplicate_key_ignore: true, track_validation_failures: true, validate: true, batch_size: 1000)
    Rails.logger.info "📊 DataImportJob: Companies import result - num_inserts: #{result.num_inserts}, failed_instances: #{result.failed_instances.size}"

    result.failed_instances.each do |failed|
      Rails.logger.warn "📊 DataImportJob: Failed company - #{failed.name} - errors: #{failed.errors.full_messages.join(', ')}"
    end
  end

  def import_persons(person_rows)
    return if person_rows.empty?
    Rails.logger.info "📊 DataImportJob: Importing #{person_rows.length} persons"

    persons = person_rows.map { |row_data| row_data[:contact] }
    result = Contact.import(persons, synchronize: persons, on_duplicate_key_ignore: true, track_validation_failures: true, validate: true, batch_size: 1000)
    Rails.logger.info "📊 DataImportJob: Persons import result - num_inserts: #{result.num_inserts}, failed_instances: #{result.failed_instances.size}"

    result.failed_instances.each do |failed|
      Rails.logger.warn "📊 DataImportJob: Failed person - #{failed.name} - errors: #{failed.errors.full_messages.join(', ')}"
    end
  end

  def process_company_linkages(person_rows)
    Rails.logger.info "📊 DataImportJob: Processing company linkages for #{person_rows.length} persons"

    person_rows.each do |person_data|
      empresas_vinculadas = person_data[:row][:empresas_vinculadas]
      next unless empresas_vinculadas.present?

      contact = person_data[:contact]
      company_names = empresas_vinculadas.split('|').map(&:strip)
      Rails.logger.debug "📊 DataImportJob: Linking #{contact.name} to companies: #{company_names.join(', ')}"

      company_names.each do |company_name|
        company = Contact.companies.find_by("LOWER(name) = ?", company_name.downcase)
        if company
          contact.add_company(company)
          Rails.logger.debug "📊 DataImportJob: Linked #{contact.name} to existing company: #{company.name}"
        else
          # Criar nova empresa se não existir
          new_company = Contact.create!(
            type: 'company',
            name: company_name,
            email: nil,
            phone_number: nil
          )
          contact.add_company(new_company)
          Rails.logger.info "📊 DataImportJob: Created new company and linked #{contact.name} to: #{company_name}"
        end
      end
    end
  end

  def update_data_import_status(processed_records, rejected_records)
    Rails.logger.info "📊 DataImportJob: Updating status - processed: #{processed_records}, rejected: #{rejected_records}"
    @data_import.update!(status: :completed, processed_records: processed_records, total_records: processed_records + rejected_records)
  end

  def save_failed_records_csv(rejected_contacts)
    csv_data = generate_csv_data(rejected_contacts)
    if csv_data.blank?
      Rails.logger.info "📊 DataImportJob: No rejected contacts to save"
      return
    end

    Rails.logger.info "📊 DataImportJob: Saving #{rejected_contacts.length} rejected contacts to CSV"
    @data_import.failed_records.attach(io: StringIO.new(csv_data), filename: "#{Time.zone.today.strftime('%Y%m%d')}_contacts.csv",
                                       content_type: 'text/csv')
    send_import_notification_to_admin
  end

  def generate_csv_data(rejected_contacts)
    headers = CSV.parse(@data_import.import_file.download, headers: true).headers
    headers << 'errors'
    return if rejected_contacts.blank?

    CSV.generate do |csv|
      csv << headers
      rejected_contacts.each do |record|
        csv << record
      end
    end
  end

  def handle_csv_error(error) # rubocop:disable Lint/UnusedMethodArgument
    Rails.logger.error "📊 DataImportJob: Handling CSV error - marking as failed"
    @data_import.update!(status: :failed)
    send_import_failed_notification_to_admin if @data_import.data_type == 'contacts'
  end

  def send_import_notification_to_admin
    Rails.logger.info "📊 DataImportJob: Sending import completion notification"
    AdministratorNotifications::AccountNotificationMailer.with(account: nil).contact_import_complete(@data_import).deliver_later
  end

  def send_import_failed_notification_to_admin
    Rails.logger.info "📊 DataImportJob: Sending import failed notification"
    AdministratorNotifications::AccountNotificationMailer.with(account: nil).contact_import_failed.deliver_later
  end
end
