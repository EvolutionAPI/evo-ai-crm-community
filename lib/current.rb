module Current
  thread_mattr_accessor :user
  thread_mattr_accessor :account
  thread_mattr_accessor :executed_by
  thread_mattr_accessor :contact
  thread_mattr_accessor :api_access_token
  thread_mattr_accessor :bearer_token
  thread_mattr_accessor :service_authenticated
  thread_mattr_accessor :authentication_method
  thread_mattr_accessor :evo_auth_validation_cache
  thread_mattr_accessor :evo_permission_cache
  thread_mattr_accessor :evo_role_key
  thread_mattr_accessor :evo_can_read_all_inboxes

  def self.reset
    Current.user = nil
    Current.account = nil
    Current.executed_by = nil
    Current.contact = nil
    Current.api_access_token = nil
    Current.bearer_token = nil
    Current.service_authenticated = nil
    Current.authentication_method = nil
    Current.evo_auth_validation_cache = nil
    Current.evo_permission_cache = nil
    Current.evo_role_key = nil
    Current.evo_can_read_all_inboxes = nil
  end
end
