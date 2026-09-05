# Configura pra qual Pipeline/Etapa uma WorkOrder recém-criada vira card
# automaticamente (ver Orders::PipelineSyncService, chamado pelo
# after_create de WorkOrder). Sem isso configurado, ordens não geram card
# nenhum — comportamento anterior, preservado por padrão.
class Api::V1::Admin::WorkOrderPipelineConfigsController < Api::V1::Admin::BaseController
  def show
    render json: { success: true, data: current_config }
  end

  def update
    InstallationConfig.find_or_initialize_by(name: 'WORK_ORDER_PIPELINE_ID')
                       .tap { |c| c.value = params[:pipeline_id].presence }.save!
    InstallationConfig.find_or_initialize_by(name: 'WORK_ORDER_PIPELINE_STAGE_ID')
                       .tap { |c| c.value = params[:pipeline_stage_id].presence }.save!

    render json: { success: true, data: current_config }
  end

  private

  def current_config
    {
      pipeline_id: GlobalConfigService.load('WORK_ORDER_PIPELINE_ID', nil),
      pipeline_stage_id: GlobalConfigService.load('WORK_ORDER_PIPELINE_STAGE_ID', nil),
      pipelines: Pipeline.includes(:pipeline_stages).map do |p|
        {
          id: p.id,
          name: p.name,
          stages: p.pipeline_stages.order(:position).map { |s| { id: s.id, name: s.name } }
        }
      end
    }
  end
end
