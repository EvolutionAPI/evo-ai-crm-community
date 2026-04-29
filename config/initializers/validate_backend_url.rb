# Defense-in-depth: config/environments/production.rb already raises if BACKEND_URL is
# missing, malformed, or points at localhost. Log here as well, so operators get a clear
# signal in log aggregators if the production.rb guard is ever weakened.
if Rails.env.production?
  backend_url_value = ENV['BACKEND_URL'].to_s.strip
  parsed = (URI.parse(backend_url_value) rescue nil)
  host = parsed&.host.to_s.downcase

  if backend_url_value.empty? || host.empty?
    Rails.logger.error '[BACKEND_URL] missing or invalid in production - webhook callbacks and route URLs will be invalid'
  elsif %w[localhost 127.0.0.1].include?(host)
    Rails.logger.error "[BACKEND_URL] points at localhost in production (#{backend_url_value.inspect}) - external integrations will fail silently"
  end
end
