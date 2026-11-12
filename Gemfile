source "https://rubygems.org"

ruby ">= 3.2.0"

# Deliberately small: the brief says to skip auth/deployment, and every extra gem
# is another way for the one-command demo to fail.
gem "rails", "~> 7.1.3"
gem "pg", "~> 1.5"
gem "puma", "~> 6.4"

# Ruby 3.4 drops csv from the default gems; the replay task still requires it.
gem "csv"
# Windows has no system zoneinfo database; unused on Linux/Docker.
gem "tzinfo-data", platforms: %i[mingw mswin x64_mingw jruby]

group :development, :test do
  gem "rspec-rails", "~> 6.1"
end
