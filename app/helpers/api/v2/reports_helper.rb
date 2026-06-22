module Api::V2::ReportsHelper
  def generate_agents_report
    reports = V2::Reports::AgentSummaryBuilder.new(
      account: nil,
      params: build_params(type: :agent)
    ).build

    User.all.map do |agent|
      report = reports.find { |r| r[:id] == agent.id }
      [agent.name] + generate_readable_report_metrics(report)
    end
  end

  def generate_inboxes_report
    reports = V2::Reports::InboxSummaryBuilder.new(
      account: nil,
      params: build_params(type: :inbox)
    ).build

    # CSV export scoped to the caller's accessible inboxes (admin/read_all/opt-in via
    # assigned_inboxes); degrade to all inboxes when no request user is set.
    (current_user&.assigned_inboxes || Inbox.all).map do |inbox|
      report = reports.find { |r| r[:id] == inbox.id }
      [inbox.name, inbox.channel&.name] + generate_readable_report_metrics(report)
    end
  end

  def generate_teams_report
    reports = V2::Reports::TeamSummaryBuilder.new(
      account: nil,
      params: build_params(type: :team)
    ).build

    Team.all.map do |team|
      report = reports.find { |r| r[:id] == team.id }
      [team.name] + generate_readable_report_metrics(report)
    end
  end

  def generate_labels_report
    Label.all.map do |label|
      label_report = report_builder({ type: :label, id: label.id }).short_summary
      [label.title] + generate_readable_report_metrics(label_report)
    end
  end

  private

  def build_params(base_params)
    base_params.merge(
      {
        since: params[:since],
        until: params[:until],
        business_hours: ActiveModel::Type::Boolean.new.cast(params[:business_hours])
      }
    )
  end

  def report_builder(report_params)
    V2::ReportBuilder.new(nil, build_params(report_params))
  end

  def generate_readable_report_metrics(report)
    [
      report[:conversations_count],
      Reports::TimeFormatPresenter.new(report[:avg_first_response_time]).format,
      Reports::TimeFormatPresenter.new(report[:avg_resolution_time]).format,
      Reports::TimeFormatPresenter.new(report[:avg_reply_time]).format,
      report[:resolved_conversations_count]
    ]
  end
end
