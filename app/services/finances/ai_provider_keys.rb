# Finances::AiProviderKeys - resolve as credenciais de IA disponíveis para os
# recursos de Financeiro (hoje: leitura de notas/recibos). Mesma prioridade
# usada em Messages::AudioTranscriptionService para OpenAI: configuração
# global primeiro, depois a integração cadastrada em Configurações >
# Integrações (Integrations::Hook). O Gemini só existe via Hook (não há
# configuração global equivalente).
module Finances::AiProviderKeys
  module_function

  def openai_key
    global = GlobalConfigService.load('OPENAI_API_SECRET', nil)
    return global if global.present?

    hook_key('openai')
  end

  def gemini_key
    hook_key('gemini')
  end

  def status
    { openai: openai_key.present?, gemini: gemini_key.present? }
  end

  def hook_key(app_id)
    hook = Integrations::Hook.find_by(app_id: app_id)
    return nil unless hook&.enabled?

    hook.settings&.[]('api_key')
  end
end
