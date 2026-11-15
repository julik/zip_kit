$LOAD_PATH.unshift File.expand_path("../../lib", __FILE__)
$LOAD_PATH.unshift(File.dirname(__FILE__))

require "minitest/autorun"
require "minitest/mock"
require "zip_kit"
require "digest"
require "fileutils"
require "shellwords"
require "zip"

require_relative "support/descriptive_tests"
require_relative "support/parallel_run"
require_relative "support/read_monitor"
require_relative "support/managed_tempfile"
require_relative "support/chunked_encoding"
require_relative "support/puma_server"
require_relative "support/allocation_assertions"
require_relative "support/raise_assertions"
require_relative "support/complexity_assertions"

class TestCase < Minitest::Test
  extend DescriptiveTests
  include ChunkedEncoding
  include AllocationAssertions
  include RaiseAssertions
  include ComplexityAssertions

  def teardown
    ManagedTempfile.prune!
    super
  end
end
