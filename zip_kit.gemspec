lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "zip_kit/version"

Gem::Specification.new do |spec|
  spec.name = "zip_kit"
  spec.version = ZipKit::VERSION
  spec.authors = ["Julik Tarkhanov", "Noah Berman", "Dmitry Tymchuk", "David Bosveld", "Felix Bünemann"]
  spec.email = ["me@julik.nl"]

  spec.summary = "Stream out ZIP files from Ruby. Successor to zip_tricks."
  spec.description = "Stream out ZIP files from Ruby. Successor to zip_tricks."
  spec.homepage = "https://github.com/julik/zip_kit"

  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features|gemfiles)/})
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rubyzip", "~> 1"

  spec.add_development_dependency "rack" # For tests where we spin up a server
  spec.add_development_dependency "rake", "~> 12.2"
  spec.add_development_dependency "rspec", "~> 3"
  spec.add_development_dependency "rspec-mocks", "~> 3.10", ">= 3.10.2" # ruby 3 compatibility
  spec.add_development_dependency "complexity_assert"
  spec.add_development_dependency "coderay"
  spec.add_development_dependency "benchmark-ips"
  spec.add_development_dependency "allocation_stats", "~> 0.1.5"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.add_development_dependency "standard", "1.28.5" # Very specific version of standard for 2.6 with _known_ settings
  spec.add_development_dependency "magic_frozen_string_literal"
  spec.add_development_dependency "puma"
  spec.add_development_dependency "actionpack", "~> 5" # For testing RailsStreaming against an actual Rails controller
  spec.add_development_dependency "nokogiri", "~> 1", ">= 1.13" # Rails 5 does by mistake use an older Nokogiri otherwise
  spec.add_development_dependency "sord"
end
