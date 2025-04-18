# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "yard"
require "standard/rake"

task :format do
  `bundle exec standardrb --fix-unsafely`
  `bundle exec magic_frozen_string_literal ./lib`
end

YARD::Rake::YardocTask.new(:doc)
RSpec::Core::RakeTask.new(:spec)

task :generate_typedefs do
  `bundle exec sord rbi/zip_kit.rbi`
  `bundle exec sord rbi/zip_kit.rbs`
end

task default: [:spec, :standard, :generate_typedefs]

# When building the gem, generate typedefs beforehand,
# so that they get included
Rake::Task["build"].enhance(["generate_typedefs"])
