# Server-side proxy for the Marketing AI tools (copy de tráfego, gerador de
# áudio, gerador de imagem/identidade, roteiro de vídeo, suite de mídia).
#
# These tools used to call ElevenLabs/Groq/Gemini/Hugging Face directly from
# the browser with the API key hardcoded in the page's own HTML — anyone
# opening view-source could read the key. This controller keeps the key
# server-side and forwards the request, so the browser never sees the
# credential.
#
# Keys are stored the same way as every other integration (OpenAI, Gemini,
# etc.): a row in `integrations_hooks` (Integrations::Hook), keyed by app_id,
# with the key under settings['api_key']. `apps.yml` defines the elevenlabs/
# groq/gemini/huggingface entries (settings_json_schema requiring api_key) so
# they validate and behave exactly like the built-in integrations.
class Api::V1::ToolsProxyController < Api::V1::BaseController
  ELEVENLABS_BASE = 'https://api.elevenlabs.io'
  GROQ_BASE = 'https://api.groq.com'
  GEMINI_BASE = 'https://generativelanguage.googleapis.com'
  HUGGINGFACE_BASE = 'https://api-inference.huggingface.co'

  # POST /api/v1/tools_proxy/elevenlabs/text_to_speech
  # body: { text, voice_id, model_id? }
  def elevenlabs_text_to_speech
    key = require_key!('elevenlabs', 'ElevenLabs')
    return if key.nil?

    voice_id = params.require(:voice_id)
    query = params[:output_format].present? ? "?output_format=#{params[:output_format]}" : ''
    response = HTTParty.post(
      "#{ELEVENLABS_BASE}/v1/text-to-speech/#{voice_id}#{query}",
      headers: { 'Content-Type' => 'application/json', 'Accept' => 'audio/mpeg', 'xi-api-key' => key },
      body: {
        text: params.require(:text),
        model_id: params[:model_id].presence || 'eleven_multilingual_v2'
      }.to_json
    )

    forward_binary(response, 'audio/mpeg')
  end

  # POST /api/v1/tools_proxy/groq/chat_completions
  # body: { messages: [...], model?, temperature? }
  def groq_chat_completions
    key = require_key!('groq', 'Groq')
    return if key.nil?

    body = {
      model: params[:model].presence || 'llama-3.3-70b-versatile',
      messages: params.require(:messages)
    }
    body[:temperature] = params[:temperature] if params[:temperature].present?

    response = HTTParty.post(
      "#{GROQ_BASE}/openai/v1/chat/completions",
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{key}" },
      body: body.to_json
    )

    forward_json(response)
  end

  # POST /api/v1/tools_proxy/gemini/generate_content
  # body: { model?, method?: 'generateContent'|'predict', payload: <full Gemini request body> }
  # `payload` is forwarded verbatim — generateContent wants `contents`, predict
  # wants `instances`/`parameters`, so the shape is the caller's, not ours to validate.
  def gemini_generate_content
    key = require_key!('gemini', 'Gemini')
    return if key.nil?

    model = params[:model].presence || 'gemini-1.5-flash-latest'
    gemini_method = params[:method].presence || 'generateContent'
    response = HTTParty.post(
      "#{GEMINI_BASE}/v1beta/models/#{model}:#{gemini_method}?key=#{key}",
      headers: { 'Content-Type' => 'application/json' },
      body: params.require(:payload).to_json
    )

    forward_json(response)
  end

  # POST /api/v1/tools_proxy/huggingface/infer
  # body: { model, inputs }
  def huggingface_infer
    key = require_key!('huggingface', 'Hugging Face')
    return if key.nil?

    model = params.require(:model)
    response = HTTParty.post(
      "#{HUGGINGFACE_BASE}/models/#{model}",
      headers: { 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{key}" },
      body: { inputs: params.require(:inputs) }.to_json
    )

    content_type = response.headers['content-type'].to_s
    if content_type.include?('image')
      forward_binary(response, content_type)
    else
      forward_json(response)
    end
  end

  private

  # Reads the credential from the same place every other integration keeps
  # it (integrations_hooks, hook_type: account). On blank, renders the
  # "not configured" error and returns nil so the caller can bail out early.
  def require_key!(app_id, label)
    key = Integrations::Hook.account_hooks.find_by(app_id: app_id)&.settings&.dig('api_key')
    return key if key.present?

    error_response(
      ApiErrorCodes::MISSING_REQUIRED_FIELD,
      "Credencial #{label} não configurada. Adicione em Configurações > Integrações.",
      status: :unprocessable_entity
    )
    nil
  end

  def forward_json(response)
    render json: response.parsed_response, status: response.code
  rescue StandardError
    render json: { raw: response.body }, status: response.code
  end

  def forward_binary(response, default_content_type)
    unless response.success?
      return error_response(
        ApiErrorCodes::EXTERNAL_SERVICE_ERROR,
        "Falha no provedor externo (#{response.code}): #{response.body}",
        status: :bad_gateway
      )
    end

    send_data response.body, type: default_content_type, disposition: 'inline'
  end
end
