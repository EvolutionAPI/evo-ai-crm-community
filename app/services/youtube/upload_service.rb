require 'net/http'
require 'uri'
require 'json'

# Sobe um vídeo pro canal do YouTube conectado via a mesma conexão Google
# usada pelo GTM/Analytics (Google::WorkspaceTokenService, escopo
# youtube.upload). Usa o protocolo de upload resumível da YouTube Data API
# v3 em dois passos: inicia a sessão (metadata) -> PUT do binário completo.
# Para os vídeos curtos de teste deste fluxo um único PUT é suficiente; um
# vídeo real de produção também cabe nesse limite (a API aceita até 128GB
# num PUT só, não é preciso quebrar em chunks pra isso funcionar).
class Youtube::UploadService
  class Error < StandardError; end

  UPLOAD_HOST = 'www.googleapis.com'.freeze

  attr_reader :upload

  def initialize(upload:)
    @upload = upload
  end

  # Retorna o ID do vídeo publicado no YouTube.
  def publish!
    raise Error, 'Upload sem vídeo anexado.' unless upload.video.attached?

    token = access_token
    raise Error, 'Conexão com o Google não encontrada. Conecte em Configurações > Integrações.' if token.blank?

    location = initiate_upload(token)
    video_id = upload_binary(location)
    upload.mark_published!(video_id)
    video_id
  end

  private

  def access_token
    Google::WorkspaceTokenService.new.access_token
  end

  def initiate_upload(token)
    uri = URI("https://#{UPLOAD_HOST}/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json; charset=UTF-8'
    request['X-Upload-Content-Type'] = upload.video.blob.content_type
    request['X-Upload-Content-Length'] = upload.video.blob.byte_size.to_s
    request.body = {
      snippet: { title: upload.title, description: upload.description.to_s },
      status: { privacyStatus: upload.privacy_status }
    }.to_json

    response = http.request(request)
    unless response.code.to_i == 200
      raise Error, "Falha ao iniciar upload (#{response.code}): #{response.body}"
    end

    response['location'] || raise(Error, 'Resposta sem header Location.')
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado ao iniciar o upload no YouTube.'
  end

  def upload_binary(location)
    uri = URI(location)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 600

    request = Net::HTTP::Put.new(uri.request_uri)
    request['Content-Type'] = upload.video.blob.content_type
    request.body = upload.video.download

    response = http.request(request)
    unless response.code.to_i.between?(200, 299)
      raise Error, "Falha no upload do vídeo (#{response.code}): #{response.body}"
    end

    body = JSON.parse(response.body)
    body['id'] || raise(Error, 'Resposta sem id do vídeo.')
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tempo esgotado durante o upload do vídeo no YouTube.'
  rescue JSON::ParserError => e
    raise Error, "Resposta inválida da YouTube Data API: #{e.message}"
  end
end
