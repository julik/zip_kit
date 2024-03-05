# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "yard"
require "rubocop/rake_task"
require "standard/rake"

task :format do
  `bundle exec standardrb --fix-unsafely`
  `bundle exec magic_frozen_string_literal ./lib`
end

YARD::Rake::YardocTask.new(:doc) do |t|
  # The dash has to be between the two to "divide" the source files and
  # miscellaneous documentation files that contain no code
  t.files = ["lib/**/*.rb", "-", "LICENSE.txt", "IMPLEMENTATION_DETAILS.md"]
end
RSpec::Core::RakeTask.new(:spec)

task :generate_typedefs do
  `bundle exec sord rbi/zip_kit.rbi`
end

task default: [:spec, :standard, :generate_typedefs]
