# Cria um PipelineItem pra uma WorkOrder recém-criada, no pipeline e etapa
# configurados (ver Api::V1::Admin::WorkOrderPipelineConfigsController) —
# sem essa configuração, não faz nada (silencioso, nunca trava a criação da
# ordem). Vincula por telefone/email a um Contact existente quando dá, ou
# cria um novo; guarda a referência da ordem em custom_fields (não há coluna
# work_order_id em PipelineItem).
class Orders::PipelineSyncService
  def self.call(work_order)
    new(work_order).call
  end

  def initialize(work_order)
    @work_order = work_order
  end

  def call
    pipeline_id = GlobalConfigService.load('WORK_ORDER_PIPELINE_ID', nil)
    stage_id = GlobalConfigService.load('WORK_ORDER_PIPELINE_STAGE_ID', nil)
    return if pipeline_id.blank? || stage_id.blank?

    stage = PipelineStage.find_by(id: stage_id, pipeline_id: pipeline_id)
    return unless stage

    PipelineItem.create!(
      pipeline_id: pipeline_id,
      pipeline_stage_id: stage.id,
      contact_id: find_or_create_contact&.id,
      entered_at: Time.current,
      custom_fields: {
        'work_order_id' => @work_order.id,
        'os_number' => @work_order.os_number,
        'total' => @work_order.total.to_s,
        'item_names' => @work_order.item_names
      }
    )
  rescue StandardError => e
    Rails.logger.error "Orders::PipelineSyncService: #{e.message}"
  end

  private

  def find_or_create_contact
    return nil if @work_order.client_name.blank? && @work_order.client_phone.blank? && @work_order.client_email.blank?

    contact = Contact.find_by(phone_number: @work_order.client_phone) if @work_order.client_phone.present?
    contact ||= Contact.find_by(email: @work_order.client_email) if @work_order.client_email.present?
    return contact if contact

    Contact.create!(
      name: @work_order.client_name.presence || "Cliente #{@work_order.os_number}",
      phone_number: @work_order.client_phone.presence,
      email: @work_order.client_email.presence
    )
  rescue StandardError => e
    Rails.logger.error "Orders::PipelineSyncService: contact error: #{e.message}"
    nil
  end
end
