Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = true
  # Request specs hit the app with "www.example.com"; no host filtering in test.
  config.hosts.clear
  # Let RSpec surface raw exceptions instead of rendered 500 pages.
  config.action_dispatch.show_exceptions = :none
  config.active_support.deprecation = :stderr
  config.active_record.verbose_query_logs = false
end
