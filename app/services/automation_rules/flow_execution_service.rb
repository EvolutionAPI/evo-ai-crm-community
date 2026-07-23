class AutomationRules::FlowExecutionService
  # Every action implementation comes from the shared
  # modules so this canvas executor runs the exact same code paths as the
  # modal AutomationRules::ActionService — no standalone reimplementations,
  # no silent divergence. This class only owns flow-control (walking nodes/
  # edges) and the node_data → action_params normalisation. See README.md.
  include AutomationRules::ConversationActionHandlers
  include AutomationRules::PipelineActionHandlers
  include AutomationRules::MessageActionHandlers

  def initialize(rule, _account = nil, conversation = nil, contact = nil, recorder: nil)
    @rule = rule
    @conversation = conversation
    @contact = contact
    @recorder = recorder
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
      change-status-node
      change-priority-node
      assign-to-pipeline-node
      move-to-pipeline-stage-node
      create-pipeline-task-node
      send-canned-response-node
      send-template-node
    ]

    action_node_types.include?(node_type)
  end

  # Normalises each canvas node's `data` into the array/hash shape the shared
  # action methods expect, then invokes the private method. Both executors
  # therefore hit identical code paths in ConversationActionHandlers /
  # PipelineActionHandlers / MessageActionHandlers.
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
          attachment_params = { attachment_ids: node_data['attachment_ids'] }
          attachment_params[:inbox_id] = node_data['inboxId'] if node_data['inboxId']
          send_attachment(attachment_params)
        end

      when 'send-webhook-node'
        send_webhook_event([node_data['webhook_url']]) if node_data['webhook_url']

      when 'mute-conversation-node'
        mute_conversation

      when 'snooze-conversation-node'
        snooze_conversation

      when 'resolve-conversation-node'
        resolve_conversation

      # Change-status was missing from the whitelist + dispatch, so
      # the node was a silent no-op. Wire it to the canonical change_status.
      when 'change-status-node'
        change_status([node_data['status']]) if node_data['status']

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
        # Canonical send_email_transcript expects a single comma-separated
        # string it can split; normalise the array/scalar node payload here.
        email = node_data['email'] || node_data['emails']
        send_email_transcript([Array(email).join(',')]) if email.present?

      # EVO-1262: 5 node types delegate to the pipeline/message modules. Node
      # data is normalised to the {id: ...} shape ActionService consumes.
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
end
