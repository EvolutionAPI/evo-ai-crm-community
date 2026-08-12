require 'aws-sdk-s3'

module ConfigTest
  class StorageTestService
    TIMEOUT = 15

    # ENV-first, matching config/storage.yml and the dynamic resolver: the test must
    # probe the provider and credentials the app actually uses, not a stale DB row.
    def call
      service = GlobalConfigService.load_env_first('ACTIVE_STORAGE_SERVICE', 'local')

      return { success: true, message: 'Local storage is always available' } if service == 'local'

      bucket = GlobalConfigService.load_env_first('STORAGE_BUCKET_NAME', nil)
      return { success: false, message: 'Bucket name not configured' } if bucket.blank?

      access_key = GlobalConfigService.load_env_first('STORAGE_ACCESS_KEY_ID', nil)
      return { success: false, message: 'Access Key ID not configured' } if access_key.blank?

      secret_key = GlobalConfigService.load_env_first('STORAGE_ACCESS_SECRET', nil, env_key: 'STORAGE_SECRET_ACCESS_KEY')
      return { success: false, message: 'Secret Access Key not configured' } if secret_key.blank?

      region = GlobalConfigService.load_env_first('STORAGE_REGION', 'auto')
      endpoint = GlobalConfigService.load_env_first('STORAGE_ENDPOINT', nil)

      client_options = {
        access_key_id: access_key,
        secret_access_key: secret_key,
        region: region,
        http_open_timeout: TIMEOUT,
        http_read_timeout: TIMEOUT,
        force_path_style: true
      }
      client_options[:endpoint] = endpoint if endpoint.present?

      client = Aws::S3::Client.new(client_options)
      client.head_bucket(bucket: bucket)

      { success: true, message: 'Storage connection successful' }
    rescue Aws::S3::Errors::Forbidden, Aws::S3::Errors::AccessDenied
      { success: false, message: 'Access denied — check credentials and bucket permissions' }
    rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchBucket
      { success: false, message: 'Bucket not found — verify bucket name and region' }
    rescue Aws::Errors::ServiceError => e
      { success: false, message: "S3 error: #{e.message}" }
    rescue Timeout::Error
      { success: false, message: "Connection timed out after #{TIMEOUT} seconds" }
    rescue StandardError => e
      { success: false, message: "Connection failed: #{e.message}" }
    end
  end
end
