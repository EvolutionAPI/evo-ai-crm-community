class AutomationRules::FlowExecutionService
  # EVO-1262: pipeline + message action implementations come from the shared
  # modules so this canvas executor delegates to the same code paths as the
  # modal AutomationRules::ActionService. See README.md in this directory for
  # how to add a new node type.
  include AutomationRules::PipelineActionHandlers
  include AutomationRules::MessageActionHandlers

  def initialize(rule, _account = nil, conversation = nil, contact = nil)
    @rule = rule
    @conversation = conversation
    @contact = contact
    Current.executed_by = rule
  end

  def perform
    return unless @rule.mode == 'flow' && @rule.flow_data.present?

    # Evitar execuções duplicadas muito próximas
    execution_key = "automation_flow_#{@rule.id}_#{@contact&.id || @conversation&.id}"
    last_execution = Rails.cache.read(execution_key)

    if last_execution && (Time.current - last_execution) < 5.seconds
      Rails.logger.info "Automation Rule #{@rule.id}: Skipping execution - too soon after last execution"
      return
    end

    # Marcar timestamp da execução
    Rails.cache.write(execution_key, Time.current, expires_in: 30.seconds)

    Rails.logger.info "Automation Rule #{@rule.id}: Executing FLOW mode with #{@rule.flow_data['nodes']&.size || 0} nodes"

    # Executa o flow seguindo a ordem das conexões
    execute_flow(@rule.flow_data)
  ensure
    Current.reset
  end

  private

  def execute_flow(flow_data)
    nodes = flow_data['nodes'] || flow_data[:nodes] || []
    edges = flow_data['edges'] || flow_data[:edges] || []

    # Encontrar o trigger node
    trigger_node = nodes.find { |node| node['type'] == 'trigger-node' || node['id'] == 'trigger-node' }

    unless trigger_node
      Rails.logger.warn "Automation Rule #{@rule.id}: No trigger node found in flow_data"
      return
    end

    Rails.logger.info "Automation Rule #{@rule.id}: Starting flow execution from trigger node"

    # Começar execução a partir do trigger
    execute_from_node(trigger_node['id'], nodes, edges, visited: Set.new)
  end

  def execute_from_node(node_id, nodes, edges, visited: Set.new, depth: 0)
    # Evitar loops infinitos
    return if visited.include?(node_id) || depth > 50

    visited.add(node_id)

    # Encontrar todas as conexões saindo deste node
    outgoing_edges = edges.select { |edge| edge['source'] == node_id }

    return if outgoing_edges.empty?

    # Processar todos os nodes conectados (suporte a bifurcações)
    outgoing_edges.each do |edge|
      target_node = nodes.find { |node| node['id'] == edge['target'] }
      next unless target_node

      # Se for um action node, executar
      execute_node_action(target_node) if action_node?(target_node['type'])

      # Continuar a execução recursivamente
      execute_from_node(target_node['id'], nodes, edges, visited: visited, depth: depth + 1)
    end
  end

  def action_node?(node_type)
    action_node_types = %w[
      assign-agent-node
      assign-team-node
      add-label-node
      remove-label-node
      send-message-node
      send-attachment-node
      send-email-team-node
      send-transcript-node
      send-webhook-node
      mute-conversation-node
      snooze-conversation-node
      resolve-conversation-node
      change-priority-node
      assign-to-pipeline-node
      move-to-pipeline-stage-node
      create-pipeline-task-node
      send-canned-response-node
      send-template-node
    ]

    action_node_types.include?(node_type)
  end

  def execute_node_action(node)
    node_type = node['type']
    node_data = node['data'] || {}

    Rails.logger.info "Automation Rule #{@rule.id}: Executing node #{node_type} (#{node['id']})"

    begin
      case node_type
      when 'assign-agent-node'
        assign_agent([node_data['agent_id']]) if node_data['agent_id']

      when 'assign-team-node'
        assign_team([node_data['team_id']]) if node_data['team_id']

      when 'add-label-node'
        add_label(node_data['label_list']) if node_data['label_list']&.any?

      when 'remove-label-node'
        remove_label(node_data['label_list']) if node_data['label_list']&.any?

      when 'send-message-node'
        send_message([node_data['message']]) if node_data['message']

      when 'send-attachment-node'
        if node_data['attachment_ids']&.any?
          attachment_params = {
            attachment_ids: node_data['attachment_ids']
          }
          attachment_params[:inbox_id] = node_data['inboxId'] if node_data['inboxId']
          send_attachment([attachment_params])
        end

      when 'send-webhook-node'
        send_webhook_event([node_data['webhook_url']]) if node_data['webhook_url']

      when 'mute-conversation-node'
        mute_conversation

      when 'snooze-conversation-node'
        snooze_conversation

      when 'resolve-conversation-node'
        resolve_conversation

      when 'change-priority-node'
        change_priority([node_data['priority']]) if node_data['priority']

      when 'send-email-team-node'
        if node_data['team_ids']&.any? && node_data['message']
          send_email_to_team([{
                               team_ids: node_data['team_ids'],
                               message: node_data['message']
                             }])
        end

      when 'send-transcript-node'
        email = node_data['email'] || node_data['emails']
        send_email_transcript([email]) if email

      # EVO-1262: 5 new node types delegate to the shared modules. Node data
      # is normalised to the {id: ...} shape that ActionService consumes so
      # both executors hit identical code paths in PipelineActionHandlers /
      # MessageActionHandlers — see README.md in this directory.
      when 'assign-to-pipeline-node'
        pipeline_id = node_data['pipeline_id'] || node_data['id']
        assign_to_pipeline([{ id: pipeline_id }]) if pipeline_id

      when 'move-to-pipeline-stage-node'
        stage_id = node_data['pipeline_stage_id'] || node_data['stage_id'] || node_data['id']
        update_pipeline_stage([{ id: stage_id }]) if stage_id

      when 'create-pipeline-task-node'
        create_pipeline_task([node_data.symbolize_keys])

      when 'send-canned-response-node'
        canned_id = node_data['canned_response_id'] || node_data['id']
        send_canned_response([{ canned_response_id: canned_id }]) if canned_id

      when 'send-template-node'
        send_template([node_data.deep_symbolize_keys])

      else
        Rails.logger.warn "Automation Rule #{@rule.id}: Unknown node type: #{node_type}"
      end

      Rails.logger.info "Automation Rule #{@rule.id}: Successfully executed node #{node_type}"

    rescue StandardError => e
      Rails.logger.error "Automation Rule #{@rule.id}: Error executing node #{node_type} (#{node['id']}): #{e.message}"
      Rails.logger.error "Automation Rule #{@rule.id}: Node data: #{node_data.inspect}"
      EvolutionExceptionTracker.new(e).capture_exception
    end
  end

  # Override webhook method para context específico de flows
  def send_webhook_event(webhook_url)
    payload_data = @conversation ? @conversation.webhook_data : (@contact&.webhook_data || {})
    payload = payload_data.merge(event: "automation_flow.#{@rule.event_name}")

    # Sanitize the webhook URL to remove any leading/trailing whitespace or tabs
    clean_url = webhook_url[0].to_s.strip
    Rails.logger.info "Automation Rule #{@rule.id}: Sending webhook to #{clean_url}"
    WebhookJob.perform_later(clean_url, payload)
  end

  # Implementações das ações básicas
  def assign_agent(agent_ids)
    return unless @conversation

    agent_id = agent_ids.is_a?(Array) ? agent_ids.first : agent_ids
    agent = User.find_by(id: agent_id)
    return unless agent

    @conversation.update!(assignee: agent)
    Rails.logger.info "Automation Rule #{@rule.id}: Assigned conversation to agent #{agent.name}"
  end

  def assign_team(team_ids)
    return unless @conversation

    team_id = team_ids.is_a?(Array) ? team_ids.first : team_ids
    team = Team.find_by(id: team_id)
    return unless team

    @conversation.update!(team: team)
    Rails.logger.info "Automation Rule #{@rule.id}: Assigned conversation to team #{team.name}"
  end

  def add_label(label_ids)
    labels = Label.where(id: label_ids)
    return if labels.empty?

    if @conversation
      @conversation.label_list.add(labels.pluck(:title))
      @conversation.save!
      Rails.logger.info "Automation Rule #{@rule.id}: Added #{labels.count} labels to conversation"
    elsif @contact
      # Ensure Current.executed_by is set to prevent loop
      Current.executed_by = @rule
      # F-2: route through the setter so `saved_change_to_label_list?`
      # dirty-tracks the change and Contact#publish_label_changes fires.
      titles = labels.pluck(:title)
      @contact.update!(label_list: (@contact.label_list + titles).uniq)
      Rails.logger.info "Automation Rule #{@rule.id}: Added #{labels.count} labels to contact #{@contact.name}"
    else
      Rails.logger.warn "Automation Rule #{@rule.id}: No conversation or contact to add labels to"
    end
  end

  def remove_label(label_ids)
    labels = Label.where(id: label_ids)
    return if labels.empty?

    if @conversation
      @conversation.label_list.remove(labels.pluck(:title))
      @conversation.save!
      Rails.logger.info "Automation Rule #{@rule.id}: Removed #{labels.count} labels from conversation"
    elsif @contact
      # Ensure Current.executed_by is set to prevent loop
      Current.executed_by = @rule
      # F-2: see add_label above — setter path dirties label_list.
      titles = labels.pluck(:title)
      @contact.update!(label_list: @contact.label_list - titles)
      Rails.logger.info "Automation Rule #{@rule.id}: Removed #{labels.count} labels from contact #{@contact.name}"
    else
      Rails.logger.warn "Automation Rule #{@rule.id}: No conversation or contact to remove labels from"
    end
  end

  def send_message(message_params)
    return unless @conversation
    return if conversation_a_tweet?

    message = message_params.is_a?(Array) ? message_params.first : message_params
    params = { content: message, private: false, content_attributes: { automation_rule_id: @rule.id } }

    Messages::MessageBuilder.new(nil, @conversation, params).perform
    Rails.logger.info "Automation Rule #{@rule.id}: Sent message to conversation"
  end

  def send_attachment(attachment_params)
    return unless @conversation
    return if conversation_a_tweet?

    # attachment_params já vem no formato correto do node
    attachment_data = attachment_params[0]

    if attachment_data.is_a?(Hash)
      blob_ids = attachment_data[:attachment_ids] || attachment_data['attachment_ids']
      inbox_id = attachment_data[:inbox_id] || attachment_data['inbox_id']
    else
      blob_ids = attachment_data
      inbox_id = nil
    end

    return unless @rule.files.attached?

    blobs = ActiveStorage::Blob.where(id: blob_ids)
    return if blobs.blank?

    # Preparar parâmetros da mensagem
    params = { content: nil, private: false, attachments: blobs }

    # Validar inbox se especificado
    if inbox_id
      inbox = Inbox.find_by(id: inbox_id)
      if inbox && @conversation.inbox != inbox
        Rails.logger.warn "Automation Rule #{@rule.id}: Inbox mismatch. Conversation inbox: #{@conversation.inbox.id}, Requested inbox: #{inbox_id}"
      end
    end

    Messages::MessageBuilder.new(nil, @conversation, params).perform
    Rails.logger.info "Automation Rule #{@rule.id}: Sent attachment with #{blobs.size} files"
  rescue StandardError => e
    Rails.logger.error "Automation Rule #{@rule.id}: Error sending attachment: #{e.message}"
    raise e
  end

  def mute_conversation
    return unless @conversation

    @conversation.mute!
    Rails.logger.info "Automation Rule #{@rule.id}: Muted conversation"
  end

  def snooze_conversation
    return unless @conversation

    @conversation.snoozed!
    Rails.logger.info "Automation Rule #{@rule.id}: Snoozed conversation"
  end

  def resolve_conversation
    return unless @conversation

    @conversation.resolved!
    Rails.logger.info "Automation Rule #{@rule.id}: Resolved conversation"
  end

  def change_priority(priority_params)
    return unless @conversation

    priority = priority_params.is_a?(Array) ? priority_params.first : priority_params
    @conversation.update!(priority: priority)
    Rails.logger.info "Automation Rule #{@rule.id}: Changed priority to #{priority}"
  end

  def send_email_to_team(team_params)
    return unless team_params.is_a?(Array) && team_params.first.is_a?(Hash)

    data = team_params.first
    team_ids = data[:team_ids] || data['team_ids']
    message = data[:message] || data['message']

    teams = Team.where(id: team_ids)
    teams.each do |team|
      TeamNotifications::AutomationNotificationMailer.conversation_creation(@conversation, team, message)&.deliver_now if @conversation
    end

    Rails.logger.info "Automation Rule #{@rule.id}: Sent email to #{teams.count} teams"
  end

  def send_email_transcript(email_params)
    return unless @conversation

    email = email_params.is_a?(Array) ? email_params.first : email_params
    return if email.blank?

    # Implementar envio de transcript por email se necessário
    Rails.logger.info "Automation Rule #{@rule.id}: Email transcript requested for #{email}"
  end

  def conversation_a_tweet?
    @conversation&.additional_attributes&.dig('type') == 'tweet'
  end
end