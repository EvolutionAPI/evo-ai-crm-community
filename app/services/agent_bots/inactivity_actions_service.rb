class AgentBots::InactivityActionsService
  def initialize(conversation, agent_bot)
    @conversation = conversation
    @agent_bot = agent_bot
    @inbox = conversation.inbox
  end

  def process
    return unless should_process?

    Rails.logger.info "[InactivityActions] Processing conversation #{@conversation.id}"

    inactivity_actions = get_sorted_actions
    return if inactivity_actions.empty?

    time_inactive_minutes = calculate_inactive_time_minutes
    last_incoming = @conversation.messages.incoming.order(created_at: :desc).first
    Rails.logger.info "[InactivityActions] Time inactive: #{time_inactive_minutes} minutes (since last incoming message at #{last_incoming&.created_at})"

    action_to_execute = find_action_to_execute(inactivity_actions, time_inactive_minutes)
    return unless action_to_execute

    execute_action(action_to_execute)
  end

  private

  def should_process?
    # Só processa se:
    # 1. Conversa está aberta ou pendente
    # 2. Tem inbox ativo
    # 3. Tem bot configurado
    # 4. Bot tem ações de inatividade configuradas
    # 5. Não tem agente humano assignado (opcional - pode ajustar conforme necessário)

    unless @conversation.open? || @conversation.pending?
      Rails.logger.debug "[InactivityActions] Skipping - conversation not open/pending (status: #{@conversation.status})"
      return false
    end

    unless @inbox.present?
      Rails.logger.debug "[InactivityActions] Skipping - no inbox"
      return false
    end

    unless @agent_bot.present?
      Rails.logger.debug "[InactivityActions] Skipping - no agent bot"
      return false
    end

    inactivity_config = @agent_bot.bot_config&.dig('inactivity_actions')
    unless inactivity_config.present? && inactivity_config.is_a?(Array) && inactivity_config.any?
      Rails.logger.debug "[InactivityActions] Skipping - no inactivity actions configured"
      return false
    end

    # Precedence: if the conversation's pipeline item sits in a stage that has
    # its own inactivity rule, the stage rule governs and the AI inactivity is
    # suppressed for this conversation (avoids double-nudging the customer).
    if stage_inactivity_governs?
      Rails.logger.debug "[InactivityActions] Skipping - stage inactivity rule governs conversation #{@conversation.id}"
      return false
    end

    # Opcionalmente, só processar se não tem agente humano assignado
    # Comente/descomente conforme necessário
    # if @conversation.assignee_id.present?
    #   Rails.logger.debug "[InactivityActions] Skipping - human agent assigned"
    #   return false
    # end

    true
  end

  # True when any pipeline item of this conversation is in a stage that carries
  # an `inactivity` automation rule. Such a stage rule takes precedence over the
  # AI inactivity feature for this conversation.
  def stage_inactivity_governs?
    @conversation.pipeline_items.includes(:pipeline_stage).any? do |item|
      rules = item.pipeline_stage&.automation_rules&.dig('rules') || []
      rules.any? { |r| r.is_a?(Hash) && (r['trigger'] || r[:trigger]) == 'inactivity' }
    end
  rescue StandardError => e
    Rails.logger.error "[InactivityActions] stage_inactivity_governs? failed: #{e.message}"
    false
  end

  def get_sorted_actions
    actions = @agent_bot.bot_config['inactivity_actions'] || []
    # Ordena por tempo (minutos) crescente
    actions.sort_by { |a| a['minutes'].to_i }
  end

  def calculate_inactive_time_minutes
    # Calcula inatividade baseado na última mensagem INCOMING (do cliente)
    # Ignora mensagens do bot para evitar resetar o timer de inatividade
    last_incoming_message = @conversation.messages.incoming.order(created_at: :desc).first
    last_activity = last_incoming_message&.created_at || @conversation.created_at

    time_diff_seconds = Time.current - last_activity
    (time_diff_seconds / 60.0).floor
  end

  def find_action_to_execute(actions, time_inactive_minutes)
    # Pega o último índice de ação executada
    last_executed_index = InactivityActionExecution.last_action_index_for(@conversation.id)

    Rails.logger.info "[InactivityActions] Last executed action index: #{last_executed_index}"

    # Procura a PRÓXIMA ação que deve ser executada (não todas de uma vez)
    actions.each_with_index do |action, index|
      action_time = action['minutes'].to_i

      # Pula ações já executadas
      next if index <= last_executed_index

      # Se o tempo de inatividade já passou do tempo da ação
      if time_inactive_minutes >= action_time
        Rails.logger.info "[InactivityActions] Found action to execute: index #{index}, type: #{action['action']}, time: #{action_time} min"
        return { config: action, index: index }
      end
    end

    Rails.logger.debug "[InactivityActions] No action to execute at this time"
    nil
  end

  def execute_action(action_data)
    action_config = action_data[:config]
    action_index = action_data[:index]
    action_type = action_config['action'] # 'interact' or 'finalize'

    Rails.logger.info "[InactivityActions] Executing action #{action_index}: #{action_type}"

    # Verifica se já foi executada (double-check por segurança)
    if InactivityActionExecution.action_executed?(@conversation.id, action_index)
      Rails.logger.warn "[InactivityActions] Action already executed, skipping"
      return
    end

    case action_type
    when 'interact'
      execute_interact_action(action_config, action_index)
    when 'finalize'
      execute_finalize_action(action_config, action_index)
    else
      Rails.logger.error "[InactivityActions] Unknown action type: #{action_type}"
    end
  end

  def execute_interact_action(action_config, action_index)
    Rails.logger.info "[InactivityActions] Executing interact action"

    configured_message = action_config['message']

    # Se tem mensagem configurada E agente é evo_ai_provider, envia para a IA gerar mensagem contextualizada
    # Caso contrário, usa a mensagem configurada diretamente
    if @agent_bot.evo_ai_provider?
      send_to_ai_agent(configured_message, action_config, action_index)
    else
      # Para outros tipos de bot (webhook, n8n), envia mensagem direta
      send_direct_message(configured_message, action_config, action_index)
    end
  end

  def send_to_ai_agent(suggested_message, action_config, action_index)
    Rails.logger.info "[InactivityActions] Sending to AI agent for contextual message generation"

    # Verifica se a conversa está elegível para resposta do bot
    # A validação completa será feita novamente quando a resposta voltar (no MessageCreator)
    # mas fazemos uma pré-validação aqui para evitar requests desnecessários
    agent_bot_inbox = @inbox.agent_bot_inbox
    if agent_bot_inbox.present? && !agent_bot_inbox.should_process_conversation?(@conversation)
      Rails.logger.warn "[InactivityActions] ⚠️  Conversation #{@conversation.id} does not match bot criteria (status/labels)"
      Rails.logger.warn "[InactivityActions] Status: #{@conversation.status}, Allowed: #{agent_bot_inbox.allowed_conversation_statuses.inspect}"
      Rails.logger.warn "[InactivityActions] Skipping inactivity action to avoid sending request to bot that won't be able to reply"
      return
    end

    # Monta payload especial para evento de inatividade
    payload = build_inactivity_payload(suggested_message, action_config)

    # Usa o HttpRequestService para enviar para o agente
    begin
      AgentBots::HttpRequestService.new(@agent_bot, payload).perform

      # Registra execução
      record_execution(action_config, action_index, 'interact', suggested_message)

      Rails.logger.info "[InactivityActions] ✅ Inactivity message sent to AI agent successfully"
      Rails.logger.info "[InactivityActions] Note: Bot response will be validated again before creating message (status/labels/ignored_labels check)"
    rescue StandardError => e
      Rails.logger.error "[InactivityActions] ❌ Error sending to AI agent: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end
  end

  def send_direct_message(message, action_config, action_index)
    Rails.logger.info "[InactivityActions] Sending direct message"

    # Cria mensagem diretamente no sistema
    begin
      message_params = {
        inbox_id: @conversation.inbox_id,
        conversation_id: @conversation.id,
        message_type: :outgoing,
        content: message,
        sender: @agent_bot,
        content_attributes: {
          automation_source: 'inactivity_action',
          action_index: action_index
        }
      }

      ::Messages::MessageBuilder.new(nil, @conversation, message_params).perform

      # Registra execução
      record_execution(action_config, action_index, 'interact', message)

      Rails.logger.info "[InactivityActions] ✅ Direct message sent successfully"
    rescue StandardError => e
      Rails.logger.error "[InactivityActions] ❌ Error sending direct message: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end
  end

  def build_inactivity_payload(suggested_message, action_config)
    # Build clear prompt for AI to understand it should generate an inactivity re-engagement message
    prompt_message = if suggested_message.present?
      "<system_message>[SYSTEM - INACTIVITY ACTION] The customer has been inactive for #{calculate_inactive_time_minutes} minutes. Generate a proactive message to re-engage the customer and send it directly as your reply. Suggestion: #{suggested_message}<important>Reply ONLY with the message text for the customer. Do NOT use any tools like send_private_message. Do NOT add meta-commentary. Just write the reengagement message directly.</important></system_message>"
    else
      "<system_message>[SYSTEM - INACTIVITY ACTION] The customer has been inactive for #{calculate_inactive_time_minutes} minutes. Generate an appropriate and contextualized message to re-engage the customer in the conversation. Be natural, empathetic, and relevant to the conversation context.<important>Reply ONLY with the message text for the customer. Do NOT use any tools like send_private_message. Do NOT add meta-commentary. Just write the reengagement message directly.</important></system_message>"
    end

    {
      event: 'inactivity_action',
      id: SecureRandom.uuid,
      message_type: 'incoming',
      content: prompt_message,
      conversation: @conversation.webhook_data.merge(id: @conversation.id),
      conversation_id: @conversation.id, # Use UUID id, not display_id
      inbox: @inbox.webhook_data,
      inbox_id: @inbox.id,
      sender: @conversation.contact.webhook_data,
      contact_id: @conversation.contact.id,
      created_at: Time.current.to_i,
      # Metadata específica para ação de inatividade
      inactivity_metadata: {
        action_type: 'interact',
        minutes_inactive: calculate_inactive_time_minutes,
        suggested_message: suggested_message,
        action_config: action_config,
        is_system_prompt: true # Flag para a IA saber que é um prompt do sistema
      }
    }
  end

  def execute_finalize_action(action_config, action_index)
    Rails.logger.info "[InactivityActions] Executing finalize action - resolving conversation"

    begin
      # Resolve a conversa
      @conversation.resolved!

      # Se tem mensagem configurada, envia antes de finalizar
      if action_config['message'].present?
        message_params = {
          inbox_id: @conversation.inbox_id,
          conversation_id: @conversation.id,
          message_type: :outgoing,
          content: action_config['message'],
          sender: @agent_bot,
          content_attributes: {
            automation_source: 'inactivity_action_finalize',
            action_index: action_index
          }
        }

        ::Messages::MessageBuilder.new(nil, @conversation, message_params).perform
      end

      # Registra execução
      record_execution(action_config, action_index, 'finalize', action_config['message'])

      Rails.logger.info "[InactivityActions] ✅ Conversation finalized successfully"
    rescue StandardError => e
      Rails.logger.error "[InactivityActions] ❌ Error finalizing conversation: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
    end
  end

  def record_execution(action_config, action_index, action_type, message_sent)
    InactivityActionExecution.create!(
      conversation_id: @conversation.id,
      agent_bot_id: @agent_bot.id,
      action_index: action_index,
      action_type: action_type,
      action_config: action_config,
      message_sent: message_sent,
      executed_at: Time.current
    )

    Rails.logger.info "[InactivityActions] Execution recorded: index #{action_index}, type #{action_type}"
  rescue StandardError => e
    Rails.logger.error "[InactivityActions] Error recording execution: #{e.message}"
    # Não propaga erro para não quebrar o fluxo
  end
end
