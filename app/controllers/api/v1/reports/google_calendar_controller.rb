# Endpoint único (despacha por `acao`) atrás da ferramenta "Calendário" em
# Meu Espaço: eventos do Google Calendar (leitura/criação), posts agendados
# (Gestor de Posts) e ações/tarefas agendadas do próprio CRM — tudo pra
# aparecer junto na mesma visão de calendário.
class Api::V1::Reports::GoogleCalendarController < Api::V1::BaseController
  def handle
    service = Google::CalendarService.new

    case params[:acao]
    when 'status'
      render json: { success: true, data: { connected: service.connected? } }
    when 'listar_eventos'
      respond(service.list_events(time_min: params.require(:time_min), time_max: params.require(:time_max)))
    when 'criar_evento'
      respond(service.create_event(
                summary: params.require(:summary),
                description: params[:description],
                start_time: params.require(:start_time),
                end_time: params.require(:end_time),
                all_day: ActiveModel::Type::Boolean.new.cast(params[:all_day])
              ))
    when 'listar_posts_agendados'
      render json: { success: true, data: scheduled_posts }
    when 'listar_acoes_agendadas'
      render json: { success: true, data: { scheduled_actions: scheduled_actions, tasks: pipeline_tasks } }
    else
      error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, "Ação desconhecida: #{params[:acao]}", status: :unprocessable_entity)
    end
  end

  private

  def respond(result)
    if result.success
      render json: { success: true, data: result.data }
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway)
    end
  end

  def scheduled_posts
    ScheduledPost.where(status: %w[scheduled executing]).order(:scheduled_for).limit(200).map do |p|
      { id: p.id, caption: p.caption, content_type: p.content_type, platforms: p.platforms,
        scheduled_for: p.scheduled_for, status: p.status }
    end
  end

  def scheduled_actions
    ScheduledAction.where(status: 'pending').order(:scheduled_for).limit(200).map do |a|
      { id: a.id, action_type: a.action_type, scheduled_for: a.scheduled_for, status: a.status }
    end
  end

  def pipeline_tasks
    PipelineTask.where(status: %w[pending overdue]).where.not(due_date: nil).order(:due_date).limit(200).map do |t|
      { id: t.id, title: t.title, due_date: t.due_date, status: t.status, priority: t.priority, task_type: t.task_type }
    end
  end
end
