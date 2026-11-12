require_relative "boot"

# API-only service: load just the railties we use. `rails/all` would pull in
# ActionCable / ActiveStorage / ActionMailbox (and their native deps) for nothing.
require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module ShipmentEventsService
  class Application < Rails::Application
    config.load_defaults 7.1
    config.api_only = true

    # Every timestamp in this domain is UTC. Never rely on the host/container TZ.
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc

    config.generators.system_tests = nil
  end
end
