# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

require "rake/extensiontask"
Rake::ExtensionTask.new("flex_json") do |ext|
  ext.ext_dir = "ext/flex_json"
  ext.lib_dir = "lib/flex_json"
end

task spec: :compile
task default: %i[clobber compile spec rubocop]
