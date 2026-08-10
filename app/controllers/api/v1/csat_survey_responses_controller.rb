class Api::V1::CsatSurveyResponsesController < Api::V1::BaseController
  require_permissions({
    index: 'csat_survey_responses.read',
    show: 'csat_survey_responses.read',
    create: 'csat_survey_responses.write',
    update: 'csat_survey_responses.write',
    destroy: 'csat_survey_responses.delete'
  })
  include Sift
  include DateRangeHelper

  RESULTS_PER_PAGE = 25

  before_action :set_csat_survey_responses, only: [:index, :metrics, :download]
  before_action :set_total_sent_messages_count, only: [:metrics]

  sort_on :created_at, type: :datetime

  def index
    
    apply_pagination
    
    paginated_response(
      data: CsatSurveyResponseSerializer.serialize_collection(
        @csat_survey_responses,
        include_conversation: true,
        include_contact: true,
        include_assigned_agent: true
      ),
      collection: @csat_survey_responses,
      message: 'CSAT survey responses retrieved successfully'
    )
  end

  def metrics
    @total_count = @csat_survey_responses.count
    @ratings_count = @csat_survey_responses.group(:rating).count
    
    success_response(
      data: {
        total_count: @total_count,
        ratings_count: @ratings_count,
        total_sent_messages_count: @total_sent_messages_count,
        response_rate: @total_sent_messages_count.positive? ? (@total_count.to_f / @total_sent_messages_count * 100).round(2) : 0
      },
      message: 'CSAT metrics retrieved successfully'
    )
  end

  def download
    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = 'attachment; filename=csat_report.csv'
    render layout: false, template: 'api/v1/csat_survey_responses/download', formats: [:csv]
  end

  private

  def set_total_sent_messages_count
    @csat_messages = Message.all.input_csat
    @csat_messages = @csat_messages.where(created_at: range) if range.present?
    @total_sent_messages_count = @csat_messages.count
  end

  def set_csat_survey_responses
    base_query = CsatSurveyResponse.all.includes([:conversation, :assigned_agent, :contact])
    @csat_survey_responses = filtrate(base_query).filter_by_created_at(range)
                                                 .filter_by_assigned_agent_id(params[:user_ids])
                                                 .filter_by_inbox_id(params[:inbox_id])
                                                 .filter_by_team_id(params[:team_id])
                                                 .filter_by_rating(params[:rating])
  end
end
