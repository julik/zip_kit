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

  # Sord inlines the VERSION literal, which would make every version bump produce a typedef diff
  rbi_path = "rbi/zip_kit.rbi"
  rbi = File.read(rbi_path).sub(/^(\s*)VERSION = T\.let\(.+\)$/, '\1VERSION = T.let(T.unsafe(nil), String)')
  File.write(rbi_path, rbi)
  rbs_path = "rbi/zip_kit.rbs"
  rbs = File.read(rbs_path).sub(/^(\s*)VERSION: untyped$/, '\1VERSION: String')
  File.write(rbs_path, rbs)
end

task default: [:spec, :standard, :generate_typedefs]

# When building the gem, generate typedefs beforehand,
# so that they get included
Rake::Task["build"].enhance(["generate_typedefs"])
