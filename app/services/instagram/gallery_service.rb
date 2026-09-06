# Leitura de mídia/insights/demografia de uma conta Instagram conectada, pra
# tela "Gestor de Posts". Substitui os nodes do n8n que faziam essas mesmas
# chamadas (Puxa_posts_instagram, dados_instagram, instagram_dados_*).
#
# Aceita tanto Channel::Instagram (Login direto do Instagram — graph.instagram.com,
# access_token próprio) quanto Channel::FacebookPage com instagram_id
# (Instagram via Login do Facebook — graph.facebook.com, page_access_token).
#
# IMPORTANTE: o campo de métrica correto é "views", não "plays" — "plays" foi
# o bug real encontrado no fluxo n8n que este serviço substitui (a Graph API
# retorna 400 "(#100) metric[x] deve ser um dos seguintes valores...").
require 'net/http'
require 'uri'
require 'json'

class Instagram::GalleryService
  MEDIA_FIELDS = 'id,caption,media_type,media_url,thumbnail_url,permalink,timestamp,like_count,comments_count,' \
                 'insights.metric(impressions,reach,saved,shares,views,total_interactions,profile_visits,follows,' \
                 'ig_reels_avg_watch_time)'.freeze
  ACCOUNT_FIELDS = 'followers_count,username,biography,name,profile_picture_url,media_count,follows_count,website'.freeze

  class Error < StandardError; end

  attr_reader :channel

  def initialize(channel:)
    @channel = channel
  end

  def account_info
    get(account_id.to_s, fields: ACCOUNT_FIELDS)
  end

  def media(limit: 25)
    result = get("#{account_id}/media", fields: MEDIA_FIELDS, limit: limit)
    result['data'] || []
  end

  # breakdown: "age,gender" ou "city"
  def demographics(breakdown:)
    get("#{account_id}/insights", metric: 'follower_demographics', period: 'lifetime',
                                   metric_type: 'total_value', breakdown: breakdown)
  end

  def peak_online_hours
    get("#{account_id}/insights", metric: 'online_followers', period: 'lifetime')
  end

  private

  def account_id
    channel.instagram_id
  end

  def access_token
    channel.is_a?(Channel::Instagram) ? channel.access_token : channel.page_access_token
  end

  def base_url
    channel.is_a?(Channel::Instagram) ? MetaBaseUrl.for(:instagram) : MetaBaseUrl.for(:facebook)
  end

  def get(path, **params)
    raise Error, 'Conta Instagram sem ID configurado.' if account_id.blank?
    raise Error, 'Conta Instagram sem token de acesso configurado.' if access_token.blank?

    uri = URI("#{base_url}/#{path}")
    uri.query = URI.encode_www_form(params.merge(access_token: access_token))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    response = http.request(Net::HTTP::Get.new(uri.request_uri))
    body = JSON.parse(response.body)

    if body['error'].present?
      raise Error, "#{body.dig('error', 'code')} - #{body.dig('error', 'message')}"
    end

    body
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da Graph API: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao consultar a Graph API do Instagram.'
  end
end
