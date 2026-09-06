# Publica uma mídia única (Feed / Stories / Reels) numa Página do Facebook, a
# partir de um GestorPosts::Upload com mídia anexada via ActiveStorage.
# Substitui facebbook_imagem / facebook_stories / facebook_reels do fluxo n8n.
#
# Correções em relação ao n8n original: legenda do Reels vem de upload.caption
# (lá o campo "description" reusava por engano a própria URL da mídia); a URL
# de Stories é usada uma única vez (lá vinha duplicada: "{{url}}{{url}}").
# Usa channel.page_access_token já armazenado — sem chain de resolução de
# token via /me/accounts.
require 'net/http'
require 'uri'
require 'json'

class Facebook::PublishService
  class Error < StandardError; end

  attr_reader :channel, :upload

  def initialize(channel:, upload: nil)
    @channel = channel
    @upload = upload
  end

  # Retorna o ID do post/vídeo publicado.
  def publish!
    raise Error, 'Upload sem mídia anexada.' unless upload.media.attached?
    raise Error, 'Canal não é uma Página do Facebook.' unless channel.is_a?(Channel::FacebookPage)

    body = case upload.content_type
           when 'feed' then post("#{channel.page_id}/photos", url: public_media_url, caption: upload.caption.to_s, published: true)
           when 'stories' then post("#{channel.page_id}/photos", url: public_media_url, caption: upload.caption.to_s,
                                                                   is_instagram_story: true, published: true)
           when 'reels' then post("#{channel.page_id}/videos", file_url: public_media_url, description: upload.caption.to_s,
                                                                 is_reels_video: true, published: true)
           else raise Error, "Tipo de conteúdo desconhecido: #{upload.content_type}"
           end

    id = body['id'] || body['post_id']
    upload.mark_platform_published!('facebook', id)
    id
  end

  # Sobe uma foto não-publicada (published: false) — vira um card do post
  # multi-foto criado por publish_carousel!. Retorna o photo id (media_fbid).
  def create_carousel_card(image_url:)
    raise Error, 'Canal não é uma Página do Facebook.' unless channel.is_a?(Channel::FacebookPage)

    body = post("#{channel.page_id}/photos", url: image_url, published: false)
    body['id']
  end

  # O Facebook não tem um "container pai" como o Instagram: um post de várias
  # fotos é um /feed post normal com attached_media apontando pros photo ids
  # não-publicados criados por create_carousel_card. Retorna o ID do post.
  def publish_carousel!(photo_ids:, caption:)
    raise Error, 'Canal não é uma Página do Facebook.' unless channel.is_a?(Channel::FacebookPage)

    params = { message: caption.to_s }
    photo_ids.each_with_index do |photo_id, index|
      params["attached_media[#{index}][media_fbid]"] = photo_id
    end

    body = post("#{channel.page_id}/feed", params)
    body['id'] || body['post_id']
  end

  private

  def public_media_url
    upload.public_media_url || raise(Error, 'Não foi possível gerar a URL pública da mídia.')
  end

  def post(path, params)
    raise Error, 'Página do Facebook sem token de acesso configurado.' if channel.page_access_token.blank?

    uri = URI("#{MetaBaseUrl.for(:facebook)}/#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 60
    http.open_timeout = 10

    request = Net::HTTP::Post.new(uri.path)
    request.set_form_data(params.merge(access_token: channel.page_access_token))

    response = http.request(request)
    body = JSON.parse(response.body)

    raise Error, "#{body.dig('error', 'code')} - #{body.dig('error', 'message')}" if body['error'].present?

    body
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da Graph API: #{e.message}"
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao publicar no Facebook.'
  end
end
