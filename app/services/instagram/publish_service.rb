# Publica uma mídia única (Feed / Stories / Reels) no Instagram, a partir de
# um GestorPosts::Upload com mídia anexada via ActiveStorage. Substitui os
# nodes instagram_subir_imagem_feed / instagram_subir_midia_stories /
# instagram_subir_midia_reels + instagram_publicar_stories do fluxo n8n.
#
# Correções em relação ao n8n original: legenda do Reels vem de verdade de
# upload.caption (lá era um texto fixo "Legenda do Reels #ReelsAPI"); a URL
# pública vem de BlobUrlOptions (ActiveStorage), não de um upload pro Dropbox.
require 'net/http'
require 'uri'
require 'json'

class Instagram::PublishService
  class Error < StandardError; end

  # A Graph API processa o container de mídia de forma assíncrona (baixa a
  # URL pública, transcodifica vídeo etc). Chamar /media_publish antes disso
  # terminar retorna o erro 9007 "Media ID is not available" — então
  # esperamos o status_code virar FINISHED (com timeout) antes de publicar.
  CONTAINER_POLL_INTERVAL = 2
  CONTAINER_POLL_MAX_ATTEMPTS = 15

  attr_reader :channel, :upload

  def initialize(channel:, upload: nil)
    @channel = channel
    @upload = upload
  end

  # Retorna o ID da mídia publicada.
  def publish!
    raise Error, 'Upload sem mídia anexada.' unless upload.media.attached?

    container_id = create_container
    wait_until_ready(container_id)
    media_id = publish_container(container_id)
    upload.mark_platform_published!('instagram', media_id)
    media_id
  end

  # Cria um container individual de um card do carrossel (is_carousel_item)
  # e espera ele terminar de processar. Retorna o container_id, que entra na
  # lista de "children" do container pai criado por publish_carousel!.
  def create_carousel_card(image_url:)
    body = post("#{account_id}/media", image_url: image_url, is_carousel_item: true)
    container_id = body['id']
    wait_until_ready(container_id)
    container_id
  end

  # Une os containers dos cards num container pai CAROUSEL e publica de
  # verdade. Retorna o ID da mídia publicada.
  def publish_carousel!(container_ids:, caption:)
    body = post("#{account_id}/media", media_type: 'CAROUSEL', children: container_ids.join(','), caption: caption.to_s)
    parent_id = body['id']
    wait_until_ready(parent_id)
    publish_container(parent_id)
  end

  private

  def wait_until_ready(container_id)
    CONTAINER_POLL_MAX_ATTEMPTS.times do
      status = get("#{container_id}", fields: 'status_code')['status_code']
      return if status == 'FINISHED'
      raise Error, "Falha ao processar a mídia (status: #{status})" if status == 'ERROR'

      sleep CONTAINER_POLL_INTERVAL
    end
    raise Error, 'Tempo esgotado aguardando o processamento da mídia.'
  end

  def create_container
    params = case upload.content_type
             when 'feed' then feed_params
             when 'stories' then stories_params
             when 'reels' then reels_params
             else raise Error, "Tipo de conteúdo desconhecido: #{upload.content_type}"
             end

    body = post("#{account_id}/media", params)
    body['id']
  end

  def feed_params
    { image_url: public_media_url, caption: upload.caption.to_s, is_carousel_item: false }
  end

  def stories_params
    { media_type: 'STORIES' }.merge(video? ? { video_url: public_media_url } : { image_url: public_media_url })
  end

  def reels_params
    { media_type: 'REELS', video_url: public_media_url, caption: upload.caption.to_s, share_to_feed: true }
  end

  def publish_container(container_id)
    body = post("#{account_id}/media_publish", creation_id: container_id)
    body['id']
  end

  def video?
    upload.media.blob.content_type.to_s.start_with?('video/')
  end

  def public_media_url
    upload.public_media_url || raise(Error, 'Não foi possível gerar a URL pública da mídia.')
  end

  def account_id
    channel.instagram_id
  end

  def access_token
    channel.is_a?(Channel::Instagram) ? channel.access_token : channel.page_access_token
  end

  def base_url
    channel.is_a?(Channel::Instagram) ? MetaBaseUrl.for(:instagram) : MetaBaseUrl.for(:facebook)
  end

  def post(path, params)
    raise Error, 'Conta Instagram sem token de acesso configurado.' if access_token.blank?

    uri = URI("#{base_url}/#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60
    http.open_timeout = 10

    request = Net::HTTP::Post.new(uri.path)
    request.set_form_data(params.merge(access_token: access_token))

    handle(http.request(request))
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao publicar no Instagram.'
  end

  def get(path, params)
    raise Error, 'Conta Instagram sem token de acesso configurado.' if access_token.blank?

    uri = URI("#{base_url}/#{path}")
    uri.query = URI.encode_www_form(params.merge(access_token: access_token))

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30
    http.open_timeout = 10

    handle(http.request(Net::HTTP::Get.new(uri.request_uri)))
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao consultar a Graph API do Instagram.'
  end

  def handle(response)
    body = JSON.parse(response.body)
    raise Error, "#{body.dig('error', 'code')} - #{body.dig('error', 'message')}" if body['error'].present?

    body
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da Graph API: #{e.message}"
  end
end
