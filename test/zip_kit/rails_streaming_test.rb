require "test_helper"

class RailsStreamingTest < TestCase
  class FakeZipGenerator
    def generate_once(streamer)
      # Only allow the call to be executed once, to ensure that we run
      # our ZIP generation block just once. This is to ensure Rack::ContentLength
      # does not run the generation twice
      raise "The ZIP has already been generated once" if @did_generate_zip
      streamer.write_file("hello.txt") do |f|
        f << "ßHello from Rails"
      end
      @did_generate_zip = true
    end

    def self.generate_reference
      StringIO.new.binmode.tap do |sio|
        ZipKit::Streamer.open(sio) do |streamer|
          new.generate_once(streamer)
        end
        sio.rewind
      end
    end
  end

  def self.load_rails_once
    return if const_defined?(:FakeController, false)

    # Defer requires of Rails components until the test runs.
    # This will make other tests fail if they use Rails-specific things
    # and run before this one
    require "action_controller"
    require "rails"
    require "zip_kit/railtie"
    ZipKit::Railtie.initializers.each(&:run)

    fake_controller = Class.new(ActionController::Base) do
      class << self
        attr_accessor :response_header_names
      end

      # Make sure both Rack middlewares which are known to cause trouble
      # are used in this controller, so that we can ensure they get bypassed.
      # Use them in the same order Rails inserts them.
      middleware.use Rack::Sendfile
      middleware.use Rack::ETag
      middleware.use Rack::Deflater
      middleware.use Rack::ContentLength # This does not get injected by Rails
      middleware.use Rack::TempfileReaper

      def stream_zip
        generator = FakeZipGenerator.new
        zip_kit_stream(auto_rename_duplicate_filenames: true) do |z|
          generator.generate_once(z)
        end
      end

      def stream_zip_with_forced_chunking
        generator = FakeZipGenerator.new
        zip_kit_stream(auto_rename_duplicate_filenames: true, use_chunked_transfer_encoding: true) do |z|
          generator.generate_once(z)
        end
      end

      def stream_zip_unbuffered
        zip_kit_stream(write_buffer_size: 0) do |z|
          z.write_stored_file("a.txt") { |f| f << "a" * 1024 }
          z.write_stored_file("b.txt") { |f| f << "b" * 1024 }
        end
      end

      def stream_zip_with_own_cache_control
        response.headers["Cache-Control"] = "no-cache"
        zip_kit_stream { |z| FakeZipGenerator.new.generate_once(z) }
      end

      def stream_zip_with_custom_content_type
        generator = FakeZipGenerator.new
        zip_kit_stream(type: "application/epub+zip") do |z|
          generator.generate_once(z)
        end
        self.class.response_header_names = response.headers.keys
      end
    end
    const_set(:FakeController, fake_controller)
  end

  def setup
    super
    self.class.load_rails_once
  end

  test "degrades to a buffered response with HTTP/1.0 and produces a ZIP" do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.0",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new
    }
    status, headers, body = FakeController.action(:stream_zip).call(fake_rack_env)
    headers = downcase_header_names(headers)

    ref_output_io = FakeZipGenerator.generate_reference
    out = readback_iterable(body)
    assert_equal ref_output_io.string, out.string
    assert_nothing_raised { body.close }
    assert_equal 200, status
    assert_correct_headers(headers)

    assert_equal "no", headers["x-accel-buffering"]
    assert_nil headers["transfer-encoding"]
    assert_kind_of String, headers["content-length"]
    # All the other methods have been excercised by reading out the iterable body
  end

  test "uses Transfer-Encoding: chunked when requested" do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.1",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new
    }
    status, headers, body = FakeController.action(:stream_zip_with_forced_chunking).call(fake_rack_env)
    headers = downcase_header_names(headers)

    ref_output_io = FakeZipGenerator.generate_reference
    out = decode_chunked_encoding(readback_iterable(body))
    assert_equal ref_output_io.string.b, out.string.b

    assert_equal 200, status
    assert_correct_headers(headers)

    assert_equal "no", headers["x-accel-buffering"]
    assert_equal "chunked", headers["transfer-encoding"]
    assert_nil headers["content-length"] # Must be unset!
    refute_respond_to body, :to_path # for Rack::Sendfile
  end

  test "gets through Rack::Deflater uncompressed, a chunk at a time, when the client accepts gzip" do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.1",
      "HTTP_ACCEPT_ENCODING" => "gzip, deflate",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new
    }
    status, headers, body = FakeController.action(:stream_zip_unbuffered).call(fake_rack_env)
    headers = downcase_header_names(headers)

    assert_equal 200, status
    assert_equal "identity", headers["content-encoding"]
    assert_includes headers["cache-control"], "no-transform"
    chunks = []
    body.each { |chunk| chunks << chunk.dup }
    body.close
    assert_operator chunks.length, :>, 1

    entries = {}
    Zip::File.open_buffer(chunks.join) { |zip_file| zip_file.each { |e| entries[e.name] = e.get_input_stream.read } }
    assert_equal({"a.txt" => "a" * 1024, "b.txt" => "b" * 1024}, entries)
  end

  test "adds no-transform to a cache-control the controller has set" do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.1",
      "HTTP_ACCEPT_ENCODING" => "gzip",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new
    }
    _status, headers, body = FakeController.action(:stream_zip_with_own_cache_control).call(fake_rack_env)
    headers = downcase_header_names(headers)
    body.close

    assert_equal "no-cache, no-transform", headers["cache-control"]
    assert_equal "identity", headers["content-encoding"]
  end

  test "honors the content type set in zip_kit_stream" do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.1",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new
    }
    status, headers, _body = FakeController.action(:stream_zip_with_custom_content_type).call(fake_rack_env)
    headers = downcase_header_names(headers)

    assert_equal 200, status
    assert_equal "application/epub+zip", headers["content-type"]
  end

  test "does not add headers Rails has already set under a differently cased name" do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.1",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new
    }
    FakeController.action(:stream_zip_with_custom_content_type).call(fake_rack_env)

    header_names = FakeController.response_header_names.map(&:downcase)
    assert_includes header_names, "content-type"
    assert_includes header_names, "x-accel-buffering"
    assert_equal header_names.uniq, header_names
  end

  def downcase_header_names(headers)
    headers.to_h.transform_keys(&:downcase)
  end

  def readback_iterable(iterable)
    StringIO.new.binmode.tap do |out|
      iterable.each { |chunk| out.write(chunk) }
      out.rewind
    end
  end

  def assert_correct_headers(headers)
    assert_equal "application/zip", headers["content-type"]
    assert_nil headers["etag"] # if the ETag middleware activates it will generate a weak ETag
    assert_kind_of String, headers["last-modified"]
    assert_equal "identity", headers["content-encoding"]
    assert_includes headers["cache-control"], "private"
    assert_includes headers["cache-control"], "no-transform"
    assert_equal "no", headers["x-accel-buffering"]
  end
end
