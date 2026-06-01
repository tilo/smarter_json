# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in smarter_json.gemspec
gemspec

# irb is part of stdlib (optional, useful for development/console)
gem "irb"

group :development do
  gem "awesome_print"
  gem "rake"            # build/package tasks
  gem "rake-compiler"   # builds the C extension
  gem "rubocop"         # linting only
end

group :test do
  gem "rspec"
  gem "simplecov", require: false
end
