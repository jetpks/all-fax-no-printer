# frozen_string_literal: true

source "https://rubygems.org"

ruby "4.0.5"

# In-tree gems
gem "hanami-credentials", path: "gems/hanami-credentials"
gem "hanami-healthcheck", path: "gems/hanami-healthcheck"
gem "hanami-force-ssl", path: "gems/hanami-force-ssl"
gem "inertia-hanami", path: "gems/inertia-hanami"
gem "vite-hanami", path: "gems/vite-hanami"

# Authentication
gem "omniauth"
gem "omniauth-github"

# Web framework
gem "hanami", "3.0.2"
gem "hanami-db", "3.0.0"
gem "hanami-action", "3.0.1"
gem "hanami-router", "3.0.0"

# Async server
gem "falcon", "0.57.0"

# Redis (display streams for the runs chain; sole consumer: config/providers/redis.rb)
gem "async-redis", "0.14.0"

# Persistence
gem "rom", "5.4.3"
gem "rom-sql", "3.7.0"
gem "sequel", "5.109.0"
gem "pg", "1.7.0"

# dry-rb suite
gem "dry-types", "1.9.1"
gem "dry-validation", "1.11.1"
gem "dry-monads", "1.11.0"
gem "dry-operation", ">= 1.0.1"

# CLI + build
gem "hanami-cli", "3.0.0"
gem "rake"

# Former stdlib gems removed in Ruby 4.0
gem "ostruct"
gem "logger"
gem "bigdecimal"
gem "base64"

group :development, :test do
  gem "dotenv"
end

group :test do
  gem "minitest"
  gem "rom-factory", "0.14.1"
  gem "faker"
end
