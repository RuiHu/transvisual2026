require "spec_helper"

ENV["RAILS_ENV"] = "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"

Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |file| require file }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => error
  abort error.to_s.strip
end

RSpec.configure do |config|
  # Concurrency examples commit from worker threads; transactional fixtures
  # would hide those writes. Start every example from a clean database.
  config.use_transactional_fixtures = false

  config.before(:each) do
    ActiveRecord::Base.connection.execute("TRUNCATE TABLE events, shipments RESTART IDENTITY")
  end

  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
