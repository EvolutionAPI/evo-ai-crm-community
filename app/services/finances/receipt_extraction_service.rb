require 'net/http'
require 'base64'

# Finances::ReceiptExtractionService - lê a foto de uma nota fiscal/recibo e
# devolve os dados estruturados (fornecedor, valor, data, forma de pagamento,
# itens) usando um modelo de visão. Suporta OpenAI e Google Gemini — quem
# chama escolhe (`provider:`) ou deixa em branco para usar o primeiro
# provedor configurado (OpenAI tem preferência quando ambos estão prontos).
class Finances::ReceiptExtractionService
  pattr_initialize [:image_bytes!, :content_type!, :provider]

  OPENAI_MODEL = 'gpt-4o-mini'
  GEMINI_MODEL = 'gemini-3.6-flash'

  PROMPT = <<~PROMPT.freeze
    Você é um assistente contábil brasileiro. Analise a imagem de uma nota fiscal,
    cupom fiscal ou recibo e devolva SOMENTE um JSON válido (sem markdown, sem texto
    adicional) no formato:
    {
      "fornecedor": "nome da empresa/loja",
      "cnpj": "CNPJ se visível, senão null",
      "endereco": "endereço se visível, senão null",
      "data_compra": "data no formato AAAA-MM-DD, senão null",
      "forma_pagamento": "forma de pagamento identificada (ex: Cartao de Credito, Dinheiro, Pix, Boleto), senão null",
      "valor_total": valor numérico total pago (ex: 45.9), senão null,
      "categoria_sugerida": "uma categoria de despesa (ex: Alimentacao, Material de Escritorio, Transporte, Fornecedores, Manutencao, Impostos)",
      "itens": [{"descricao": "...", "quantidade": numero ou null, "valor_unitario": numero ou null}]
    }
    Nunca invente valores: se um campo não estiver legível, use null. Responda apenas o JSON.
  PROMPT

  def call
    resolved_provider = provider.presence || default_provider
    return failure('Nenhum provedor de IA está configurado (OpenAI ou Gemini).') unless resolved_provider

    content =
      case resolved_provider
      when 'gemini'
        extract_with_gemini
      else
        extract_with_openai
      end

    return content if content.is_a?(Hash) && content[:success] == false

    { success: true, data: normalize(JSON.parse(content)), provider: resolved_provider }
  rescue JSON::ParserError => e
    Rails.logger.error "ReceiptExtractionService: JSON parse error: #{e.message}"
    failure('Não foi possível interpretar a resposta da IA.')
  rescue StandardError => e
    Rails.logger.error "ReceiptExtractionService: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    failure('Erro inesperado ao analisar a nota fiscal.')
  end

  private

  def default_provider
    return 'openai' if Finances::AiProviderKeys.openai_key.present?
    return 'gemini' if Finances::AiProviderKeys.gemini_key.present?

    nil
  end

  def failure(message)
    { success: false, error: message }
  end

  # --- OpenAI ---------------------------------------------------------

  def extract_with_openai
    api_key = Finances::AiProviderKeys.openai_key
    return failure('Integração com a OpenAI não está configurada.') unless api_key.present?

    base_url = GlobalConfigService.load('OPENAI_API_URL', 'https://api.openai.com/v1')
    uri = URI("#{base_url}/chat/completions")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{api_key}"
    request['Content-Type'] = 'application/json'
    request.body = {
      model: OPENAI_MODEL,
      response_format: { type: 'json_object' },
      temperature: 0.1,
      max_tokens: 1000,
      messages: [
        { role: 'system', content: PROMPT },
        {
          role: 'user',
          content: [
            {
              type: 'image_url',
              image_url: { url: "data:#{content_type};base64,#{Base64.strict_encode64(image_bytes)}" }
            }
          ]
        }
      ]
    }.to_json

    response = http.request(request)
    unless response.code == '200'
      Rails.logger.error "ReceiptExtractionService: OpenAI error #{response.code} - #{response.body}"
      return failure('Falha ao consultar a OpenAI.')
    end

    JSON.parse(response.body).dig('choices', 0, 'message', 'content').presence ||
      failure('A OpenAI não retornou nenhum conteúdo.')
  end

  # --- Gemini -----------------------------------------------------------

  def extract_with_gemini
    api_key = Finances::AiProviderKeys.gemini_key
    return failure('Integração com o Google Gemini não está configurada.') unless api_key.present?

    uri = URI("https://generativelanguage.googleapis.com/v1beta/models/#{GEMINI_MODEL}:generateContent?key=#{api_key}")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Content-Type'] = 'application/json'
    request.body = {
      contents: [
        {
          role: 'user',
          parts: [
            { text: PROMPT },
            { inline_data: { mime_type: content_type, data: Base64.strict_encode64(image_bytes) } }
          ]
        }
      ],
      generationConfig: {
        temperature: 0.1,
        response_mime_type: 'application/json'
      }
    }.to_json

    response = http.request(request)
    unless response.code == '200'
      Rails.logger.error "ReceiptExtractionService: Gemini error #{response.code} - #{response.body}"
      return failure('Falha ao consultar o Google Gemini.')
    end

    JSON.parse(response.body).dig('candidates', 0, 'content', 'parts', 0, 'text').presence ||
      failure('O Gemini não retornou nenhum conteúdo.')
  end

  def normalize(parsed)
    {
      fornecedor: parsed['fornecedor'],
      cnpj: parsed['cnpj'],
      endereco: parsed['endereco'],
      data_compra: parsed['data_compra'],
      forma_pagamento: parsed['forma_pagamento'],
      valor_total: parsed['valor_total'],
      categoria_sugerida: parsed['categoria_sugerida'],
      itens: Array(parsed['itens'])
    }
  end
end
