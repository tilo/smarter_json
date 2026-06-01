# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

require "rake/extensiontask"
Rake::ExtensionTask.new("smarter_json") do |ext|
  ext.ext_dir = "ext/smarter_json"
  ext.lib_dir = "lib/smarter_json"
end

task spec: :compile
# rubocop is NOT in the default task: `bundle exec rake` = build + test only, so it
# runs on every Ruby in the CI matrix (incl. 2.5–2.7, where the latest rubocop won't
# install). Lint runs as its own CI step on one modern Ruby. Locally: `rake rubocop`.
task default: %i[clobber compile spec]
