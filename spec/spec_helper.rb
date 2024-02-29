$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
$LOAD_PATH.unshift(File.dirname(__FILE__))

require "rspec"
require "zip_kit"
require "digest"
require "fileutils"
require "shellwords"
require "zip"

require_relative "support/read_monitor"
require_relative "support/managed_tempfile"
require_relative "support/chunked_encoding"
require_relative "support/allocate_under_matcher"

RSpec.configure do |config|
  config.include ChunkedEncoding

  config.after :each do
    ManagedTempfile.prune!
  end
end
