require "test_helper"

class OutputEnumeratorTest < TestCase
  test "returns parts of the ZIP file when called via #each with immediate yield" do
    output_buf = ManagedTempfile.new("output")

    file_body = Random.new.bytes(1024 * 1024 + 8981)

    body = ZipKit::OutputEnumerator.new { |zip|
      zip.add_stored_entry(filename: "A file",
        size: file_body.bytesize,
        crc32: Zlib.crc32(file_body))
      zip << file_body
    }

    body.each do |some_data|
      output_buf << some_data
    end

    output_buf.rewind
    assert_equal 1_057_711, output_buf.size

    per_filename = {}
    Zip::File.open(output_buf.path) do |zip_file|
      # Handle entries one by one
      zip_file.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    assert per_filename.key?("A file")
    assert_equal file_body.bytesize, per_filename["A file"].bytesize
  end

  test "provides streaming headers on the object instance" do
    headers = ZipKit::OutputEnumerator.new.streaming_http_headers
    assert_kind_of Hash, headers
    assert_equal "identity", headers["content-encoding"]
  end

  test "provides streaming headers on the class" do
    headers = ZipKit::OutputEnumerator.streaming_http_headers
    assert_kind_of Hash, headers
    assert_equal "identity", headers["content-encoding"]
  end

  test "gets through Rack::Deflater uncompressed, a chunk at a time" do
    require "rack"
    trail = []
    body = ZipKit::OutputEnumerator.new(write_buffer_size: 0) do |zip|
      zip.write_stored_file("a.txt") { |f| f << "a" * 1024 }
      zip.write_stored_file("b.txt") { |f| f << "b" * 1024 }
      trail << :archive_done
    end
    app = ->(_env) { [200, body.streaming_http_headers, body] }
    env = Rack::MockRequest.env_for("/download.zip", "HTTP_ACCEPT_ENCODING" => "gzip")
    _status, headers, deflater_body = Rack::Deflater.new(app).call(env)

    assert_equal "identity", headers["content-encoding"]
    out = StringIO.new.binmode
    deflater_body.each do |chunk|
      trail << :chunk
      out << chunk
    end
    assert_equal :chunk, trail.first # bytes go out before the archive is finished, not all at once
    assert_operator trail.count(:chunk), :>, 1

    entries = {}
    Zip::File.open_buffer(out.string) { |zip_file| zip_file.each { |e| entries[e.name] = e.get_input_stream.read } }
    assert_equal({"a.txt" => "a" * 1024, "b.txt" => "b" * 1024}, entries)
  end

  test "provides streaming headers with lowercase names, as Rack 3 requires" do
    headers = ZipKit::OutputEnumerator.streaming_http_headers
    assert_equal ["last-modified", "cache-control", "content-encoding", "x-accel-buffering", "content-type"].sort, headers.keys.sort
  end

  test "returns parts of the ZIP file when called using an Enumerator" do
    output_buf = ManagedTempfile.new("output")

    file_body = Random.new.bytes(1024 * 1024 + 8981)

    body = ZipKit::OutputEnumerator.new { |zip|
      zip.add_stored_entry(filename: "A file",
        size: file_body.bytesize,
        crc32: Zlib.crc32(file_body))
      zip << file_body
    }

    enum = body.each
    enum.each do |some_data|
      output_buf << some_data
    end

    output_buf.rewind
    assert_equal 1_057_711, output_buf.size

    per_filename = {}
    Zip::File.open(output_buf.path) do |zip_file|
      # Handle entries one by one
      zip_file.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    assert per_filename.key?("A file")
    assert_equal file_body.bytesize, per_filename["A file"].bytesize
  end

  test "is usable as a Rack response body, supports each()" do
    output_buf = ManagedTempfile.new("output")

    file_body = Random.new.bytes(1024 * 1024 + 8981)

    body = ZipKit::OutputEnumerator.new { |zip|
      zip.add_stored_entry(filename: "A file",
        size: file_body.bytesize,
        crc32: Zlib.crc32(file_body))
      zip << file_body
    }

    body.each do |some_data|
      output_buf << some_data
    end

    output_buf.rewind
    assert_equal 1_057_711, output_buf.size

    per_filename = {}
    Zip::File.open(output_buf.path) do |zip_file|
      # Handle entries one by one
      zip_file.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    assert per_filename.key?("A file")
    assert_equal file_body.bytesize, per_filename["A file"].bytesize
  end

  test "supports unbuffered output with write_buffer_size: 0" do
    output_zip = ->(zip) {
      rng = Random.new(Minitest.seed)
      200.times do |n|
        zip.write_file("file_#{n}.bin") do |sink|
          sink.write(rng.bytes(10))
        end
      end
    }

    enum = ZipKit::OutputEnumerator.new(&output_zip)
    output_chunks = []
    enum.each do |some_data|
      output_chunks << some_data.dup
    end
    assert_equal 1, output_chunks.length

    enum = ZipKit::OutputEnumerator.new(write_buffer_size: 0, &output_zip)
    output_chunks = []
    enum.each do |some_data|
      output_chunks << some_data.dup
    end
    assert_operator output_chunks.length, :>, 100
  end

  test "outputs an enumerable body suitable for a chunked HTTP response" do
    random_bytes = Random.new(Minitest.seed).bytes(10)
    enum = ZipKit::OutputEnumerator.new { |zip|
      zip.write_stored_file("test.bin") do |writable|
        writable << random_bytes
      end
    }
    headers, rack_body = enum.to_headers_and_rack_response_body(nil, anything: nil, content_length: nil)
    assert_kind_of String, headers["last-modified"]
    assert_nil headers["content-length"]
    assert_nil headers["transfer-encoding"]

    assert_equal enum, rack_body
  end
end
