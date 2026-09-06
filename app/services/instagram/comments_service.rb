# Leitura e resposta de comentários de posts do Instagram, pra tela "Gestor
# de Posts". Substitui comentarios_instagram / instagram_responder_comentario
# do fluxo n8n — lá o comment_id e o texto da resposta estavam fixos no
# código (dados de teste esquecidos); aqui os dois sempre vêm da requisição.
require 'net/http'
require 'uri'
require 'json'

class Instagram::CommentsService
  COMMENT_FIELDS = 'id,text,username,timestamp,like_count,from'.freeze

  class Error < StandardError; end

  attr_reader :channel

  def initialize(channel:)
    @channel = channel
  end

  def list(post_id)
    result = get("#{post_id}/comments", fields: COMMENT_FIELDS)
    result['data'] || []
  end

  def reply(comment_id:, text:)
    post("#{comment_id}/replies", message: text)
  end

  private

  def access_token
    channel.is_a?(Channel::Instagram) ? channel.access_token : channel.page_access_token
  end

  def base_url
    channel.is_a?(Channel::Instagram) ? MetaBaseUrl.for(:instagram) : MetaBaseUrl.for(:facebook)
  end

  def get(path, **params)
    raise Error, 'Conta Instagram sem token de acesso configurado.' if access_token.blank?

    uri = URI("#{base_url}/#{path}")
    uri.query = URI.encode_www_form(params.merge(access_token: access_token))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    handle(http.request(Net::HTTP::Get.new(uri.request_uri)))
  end

  def post(path, **params)
    raise Error, 'Conta Instagram sem token de acesso configurado.' if access_token.blank?

    uri = URI("#{base_url}/#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    request = Net::HTTP::Post.new(uri.path)
    request.set_form_data(params.merge(access_token: access_token))

    handle(http.request(request))
  end

  def handle(response)
    body = JSON.parse(response.body)
    raise Error, "#{body.dig('error', 'code')} - #{body.dig('error', 'message')}" if body['error'].present?

    body
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da Graph API: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao consultar a Graph API do Instagram.'
  end
end
