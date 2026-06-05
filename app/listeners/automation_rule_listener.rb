class AutomationRuleListener < BaseListener
  PIPELINE_STAGE_DEDUP_WINDOW = (ENV.fetch('AUTOMATION_PIPELINE_STAGE_DEDUP_WINDOW_SECONDS', 5).to_i)

  def conversation_updated(event)
    process_conversation_event(event, 'conversation_updated')
  end

  def conversation_created(event)
    process_conversation_event(event, 'conversation_created')
  end

  def conversation_opened(event)
    process_conversation_event(event, 'conversation_opened')
  end

  def message_created(event)
    return if ignore_message_created_event?(event)

    message = event.data[:message]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?('message_created', account)

    rules = current_account_rules('message_created', account)

    rules.each do |rule|
      evaluate_and_execute_rule(
        rule: rule,
        conversation: message&.conversation,
        account: account,
        changed_attributes: changed_attributes,
        message: message,
        payload: { message_id: message&.id, conversation_id: message&.conversation_id, changed_attributes: changed_attributes }
      )
    end
  end

  def pipeline_stage_updated(event)
    return if performed_by_automation?(event)

    pipeline_item = event.data[:pipeline_item]
    conversation = pipeline_item&.conversation
    account = nil
    changed_attributes = event.data[:changed_attributes] || build_default_changed_attributes(pipeline_item)

    Rails.logger.info "[AutomationRuleListener] pipeline_stage_updated received: pipeline_item=#{pipeline_item&.id} conversation=#{conversation&.id} changed_attributes=#{changed_attributes.inspect}"

    return unless rule_present?('pipeline_stage_updated', account)

    rules = current_account_rules('pipeline_stage_updated', account)
    current_stage_id = pipeline_item&.pipeline_stage_id

    rules.each do |rule|
      if pipeline_item_rule_recently_fired?(rule.id, pipeline_item&.id, current_stage_id)
        Rails.logger.info "[AutomationRuleListener] rule #{rule.id} skipped (dedup): pipeline_item=#{pipeline_item&.id} stage=#{current_stage_id} already fired in last #{PIPELINE_STAGE_DEDUP_WINDOW}s"
        record_dedup_skip(rule, pipeline_item, current_stage_id, changed_attributes)
        next
      end

      evaluate_and_execute_rule(
        rule: rule,
        conversation: conversation,
        account: account,
        changed_attributes: changed_attributes,
        payload: { pipeline_item_id: pipeline_item&.id, conversation_id: conversation&.id, changed_attributes: changed_attributes }
      )

      mark_pipeline_item_rule_fired(rule.id, pipeline_item&.id, current_stage_id)
    end
  end

  def conversation_resolved(event)
    process_conversation_event(event, 'conversation_resolved')
  end

  def conversation_status_changed(event)
    process_conversation_event(event, 'conversation_status_changed')
  end

  def contact_created(event)
    return if performed_by_automation?(event)

    contact = event.data[:contact]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?('contact_created', account)

    rules = current_account_rules('contact_created', account)

    rules.each do |rule|
      # Para eventos de contato que só têm condições de contato (ou nenhuma),
      # não precisamos de uma conversa. Avalia + executa via execução nativa de
      # contato, registrando o run no automation_rule_runs (observabilidade).
      if rule_has_only_contact_conditions?(rule)
        evaluate_and_execute_contact_rule(rule, contact, changed_attributes)
      else
        # Se tiver condições de conversa, precisa de uma conversa
        conversation = contact.conversations.last
        next unless conversation

        conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { contact: contact, changed_attributes: changed_attributes }).perform
        if conditions_match.present?
          if rule.mode == 'flow' && rule.flow_data.present?
            AutomationRules::FlowExecutionService.new(rule, account, conversation, contact).perform
          else
            ::AutomationRules::ActionService.new(rule, account, conversation).perform
          end
        end
      end
    end
  end

  def contact_updated(event)
    return if performed_by_automation?(event)

    contact = event.data[:contact]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    # Evitar loop infinito - múltiplas estratégias de detecção

    # 1. Se changed_attributes está vazio, pode ser um evento de automação não detectado
    if changed_attributes.blank? || changed_attributes.empty?
      Rails.logger.info "Automation Rule: Skipping contact_updated for contact #{contact.id} - empty changed_attributes"
      return
    end

    # 2. Removido a proteção excessiva de labels - automações podem ser executadas quando labels mudam

    # 3. Verificar se há muitos eventos recentes do mesmo contato (proteção contra spam)
    recent_events_key = "contact_updated_#{contact.id}"
    recent_count = Rails.cache.read(recent_events_key) || 0

    if recent_count > 5
      Rails.logger.warn "Automation Rule: Skipping contact_updated for contact #{contact.id} - too many recent events (#{recent_count})"
      return
    end

    # Incrementar contador de eventos recentes (expira em 30 segundos)
    Rails.cache.write(recent_events_key, recent_count + 1, expires_in: 30.seconds)

    # Log para debug das mudanças
    Rails.logger.debug do
      "Automation Rule: Processing contact_updated for contact #{contact.id} - changed attributes: #{changed_attributes.keys.sort}"
    end

    return unless rule_present?('contact_updated', account)

    rules = current_account_rules('contact_updated', account)

    rules.each do |rule|
      # Para eventos de contato que só têm condições de contato (ou nenhuma),
      # não precisamos de uma conversa. Avalia + executa via execução nativa de
      # contato, registrando o run no automation_rule_runs (observabilidade).
      if rule_has_only_contact_conditions?(rule)
        evaluate_and_execute_contact_rule(rule, contact, changed_attributes)
      else
        # Se tiver condições de conversa, precisa de uma conversa
        conversation = contact.conversations.last
        next unless conversation

        conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, { contact: contact, changed_attributes: changed_attributes }).perform
        if conditions_match.present?
          if rule.mode == 'flow' && rule.flow_data.present?
            AutomationRules::FlowExecutionService.new(rule, account, conversation, contact).perform
          else
            ::AutomationRules::ActionService.new(rule, account, conversation).perform
          end
        end
      end
    end
  end

  def rule_present?(event_name, _account = nil)
    current_account_rules(event_name).any?
  end

  def current_account_rules(event_name, _account = nil)
    AutomationRule.where(event_name: event_name, active: true)
  end

  def performed_by_automation?(event)
    event.data[:performed_by].present? && event.data[:performed_by].instance_of?(AutomationRule)
  end

  def ignore_message_created_event?(event)
    message = event.data[:message]
    performed_by_automation?(event) || message.activity?
  end

  private

  def record_dedup_skip(rule, pipeline_item, stage_id, changed_attributes)
    recorder = ::AutomationRules::RunRecorder.new(
      rule: rule,
      event_name: 'pipeline_stage_updated',
      payload: { pipeline_item_id: pipeline_item&.id, stage_id: stage_id, changed_attributes: changed_attributes }
    )
    recorder.add_step('Event received', data: { event_name: 'pipeline_stage_updated', changed_attributes: changed_attributes })
    recorder.skipped!("Duplicate event for pipeline_item=#{pipeline_item&.id} stage=#{stage_id} within #{PIPELINE_STAGE_DEDUP_WINDOW}s window")
    recorder.persist!
  end

  # When the contact_updated spam circuit breaker trips, record ONE skipped run
  # per active rule per window (cache-guarded) so the drop is visible in the logs
  # without flooding automation_rule_runs during a bulk update storm.


  def pipeline_stage_dedup_key(rule_id, pipeline_item_id, stage_id)
    "automation:pipeline_stage_updated:#{rule_id}:#{pipeline_item_id}:#{stage_id}"
  end

  def pipeline_item_rule_recently_fired?(rule_id, pipeline_item_id, stage_id)
    return false if pipeline_item_id.blank? || stage_id.blank?

    Rails.cache.exist?(pipeline_stage_dedup_key(rule_id, pipeline_item_id, stage_id))
  end

  def mark_pipeline_item_rule_fired(rule_id, pipeline_item_id, stage_id)
    return if pipeline_item_id.blank? || stage_id.blank?

    Rails.cache.write(
      pipeline_stage_dedup_key(rule_id, pipeline_item_id, stage_id),
      true,
      expires_in: PIPELINE_STAGE_DEDUP_WINDOW.seconds
    )
  end

  def process_conversation_event(event, event_name)
    return if performed_by_automation?(event)

    conversation = event.data[:conversation]
    account = nil
    changed_attributes = event.data[:changed_attributes]

    return unless rule_present?(event_name, account)

    rules = current_account_rules(event_name, account)

    rules.each do |rule|
      evaluate_and_execute_rule(
        rule: rule,
        conversation: conversation,
        account: account,
        changed_attributes: changed_attributes,
        payload: { conversation_id: conversation&.id, changed_attributes: changed_attributes }
      )
    end
  end

  def evaluate_and_execute_rule(rule:, conversation:, account:, changed_attributes:, payload: {}, message: nil, contact: nil)
    recorder = ::AutomationRules::RunRecorder.new(rule: rule, event_name: rule.event_name, payload: payload)
    recorder.add_step('Event received', data: { event_name: rule.event_name, changed_attributes: changed_attributes })

    if conversation.nil?
      recorder.skipped!('No conversation linked to event (pipeline_item without conversation, etc.)')
      recorder.persist!
      return
    end

    options = { changed_attributes: changed_attributes }
    options[:message] = message if message
    options[:contact] = contact if contact

    conditions_match = ::AutomationRules::ConditionsFilterService.new(rule, conversation, options).perform
    recorder.add_step(
      'Conditions evaluated',
      level: conditions_match ? 'success' : 'info',
      data: { matched: !!conditions_match, conditions: rule.conditions }
    )

    unless conditions_match
      recorder.no_match!
      recorder.persist!
      return
    end

    if rule.mode == 'flow' && rule.flow_data.present?
      recorder.add_step('Executing flow', data: { mode: 'flow' })
      AutomationRules::FlowExecutionService.new(rule, account, conversation).perform
    else
      Array(rule.actions).each do |action|
        action_hash = action.respond_to?(:to_h) ? action.to_h : action
        recorder.add_step(
          "Action: #{action_hash['action_name'] || action_hash[:action_name]}",
          level: 'success',
          data: { params: action_hash['action_params'] || action_hash[:action_params] }
        )
      end
      AutomationRules::ActionService.new(rule, account, conversation).perform
    end

    recorder.matched!
    recorder.persist!
  rescue StandardError => e
    Rails.logger.error "[AutomationRuleListener] evaluate_and_execute_rule failed rule=#{rule&.id}: #{e.class}: #{e.message}"
    recorder.error!(e)
    recorder.persist!
  end

  def build_default_changed_attributes(pipeline_item)
    {
      'pipeline_stage_id' => [
        pipeline_item.pipeline_stage_id_previously_was,
        pipeline_item.pipeline_stage_id
      ]
    }
  end

  def rule_has_only_contact_conditions?(rule)
    # Verifica se todas as condições são de contato
    contact_attributes = %w[name email phone_number identifier country_code city company labels blocked]
    rule.conditions.all? do |condition|
      contact_attributes.include?(condition['attribute_key'])
    end
  end

  def evaluate_contact_conditions(rule, contact, changed_attributes)
    # Avalia condições simples de contato
    rule.conditions.all? do |condition|
      attribute_key = condition['attribute_key']
      filter_operator = condition['filter_operator']
      values = condition['values']

      case attribute_key
      when 'labels'
        # Para labels, verifica se o contato tem as labels especificadas
        contact_labels = contact.label_list
        case filter_operator
        when 'equal_to'
          label_ids = values
          label_titles = Label.where(id: label_ids).pluck(:title)
          (label_titles - contact_labels).empty?
        when 'not_equal_to'
          label_ids = values
          label_titles = Label.where(id: label_ids).pluck(:title)
          (label_titles & contact_labels).empty?
        when 'is_present'
          contact_labels.any?
        when 'is_not_present'
          contact_labels.empty?
        else
          false
        end
      when 'name', 'email', 'phone_number', 'identifier'
        # Atributos simples do contato
        contact_value = contact.send(attribute_key)
        case filter_operator
        when 'equal_to'
          values.include?(contact_value)
        when 'not_equal_to'
          !values.include?(contact_value)
        when 'contains'
          values.any? { |v| contact_value&.include?(v) }
        when 'does_not_contain'
          values.none? { |v| contact_value&.include?(v) }
        when 'is_present'
          contact_value.present?
        when 'is_not_present'
          contact_value.blank?
        else
          false
        end
      when 'blocked'
        case filter_operator
        when 'equal_to'
          contact.blocked == (values.first == 'true')
        when 'not_equal_to'
          contact.blocked != (values.first == 'true')
        else
          false
        end
      when 'city', 'country_code', 'company'
        # Atributos adicionais
        contact_value = contact.additional_attributes&.dig(attribute_key)
        case filter_operator
        when 'equal_to'
          values.include?(contact_value)
        when 'not_equal_to'
          !values.include?(contact_value)
        when 'contains'
          values.any? { |v| contact_value&.include?(v) }
        when 'does_not_contain'
          values.none? { |v| contact_value&.include?(v) }
        when 'is_present'
          contact_value.present?
        when 'is_not_present'
          contact_value.blank?
        else
          false
        end
      else
        false
      end
    end
  end

  # Contact-triggered rule with only-contact (or no) conditions: evaluate and
  # execute without a conversation, recording the run so it shows up in the
  # automation logs. Native contact actions (webhook, contact labels) run;
  # conversation-bound actions are recorded as skipped with a reason by the
  # ContactActionService.
  def evaluate_and_execute_contact_rule(rule, contact, changed_attributes)
    recorder = ::AutomationRules::RunRecorder.new(
      rule: rule,
      event_name: rule.event_name,
      payload: { contact_id: contact&.id, changed_attributes: changed_attributes }
    )
    recorder.add_step('Event received', data: { event_name: rule.event_name, changed_attributes: changed_attributes })

    conditions_match = evaluate_contact_conditions(rule, contact, changed_attributes)
    recorder.add_step(
      'Conditions evaluated',
      level: conditions_match ? 'success' : 'info',
      data: { matched: !!conditions_match, conditions: rule.conditions }
    )

    unless conditions_match
      recorder.no_match!
      recorder.persist!
      return
    end

    if rule.mode == 'flow' && rule.flow_data.present?
      recorder.add_step('Executing flow', data: { mode: 'flow' })
      AutomationRules::FlowExecutionService.new(rule, nil, nil, contact).perform
    else
      AutomationRules::ContactActionService.new(rule, contact, recorder: recorder).perform
    end

    recorder.matched!
    recorder.persist!
  rescue StandardError => e
    Rails.logger.error "[AutomationRuleListener] evaluate_and_execute_contact_rule failed rule=#{rule&.id}: #{e.class}: #{e.message}"
    recorder.error!(e)
    recorder.persist!
  end

  # Contact-triggered rule that references conversation attributes: needs the
  # contact's last conversation. Records the run either way (matched / no_match /
  # skipped-no-conversation) so it's visible in the logs instead of vanishing.

end
