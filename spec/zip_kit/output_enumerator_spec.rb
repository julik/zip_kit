require_relative "../spec_helper"

describe ZipKit::OutputEnumerator do
  it "returns parts of the ZIP file when called via #each with immediate yield" do
    output_buf = ManagedTempfile.new("output")

    file_body = Random.new.bytes(1024 * 1024 + 8981)

    body = described_class.new { |zip|
      zip.add_stored_entry(filename: "A file",
        size: file_body.bytesize,
        crc32: Zlib.crc32(file_body))
      zip << file_body
    }

    body.each do |some_data|
      output_buf << some_data
    end

    output_buf.rewind
    expect(output_buf.size).to eq(1_057_711)

    per_filename = {}
    Zip::File.open(output_buf.path) do |zip_file|
      # Handle entries one by one
      zip_file.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    expect(per_filename).to have_key("A file")
    expect(per_filename["A file"].bytesize).to eq(file_body.bytesize)
  end

  it "returns parts of the ZIP file when called using an Enumerator" do
    output_buf = ManagedTempfile.new("output")

    file_body = Random.new.bytes(1024 * 1024 + 8981)

    body = described_class.new { |zip|
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
    expect(output_buf.size).to eq(1_057_711)

    per_filename = {}
    Zip::File.open(output_buf.path) do |zip_file|
      # Handle entries one by one
      zip_file.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    expect(per_filename).to have_key("A file")
    expect(per_filename["A file"].bytesize).to eq(file_body.bytesize)
  end

  it "is usable as a Rack response body, supports each()" do
    output_buf = ManagedTempfile.new("output")

    file_body = Random.new.bytes(1024 * 1024 + 8981)

    body = described_class.new { |zip|
      zip.add_stored_entry(filename: "A file",
        size: file_body.bytesize,
        crc32: Zlib.crc32(file_body))
      zip << file_body
    }

    body.each do |some_data|
      output_buf << some_data
    end

    output_buf.rewind
    expect(output_buf.size).to eq(1_057_711)

    per_filename = {}
    Zip::File.open(output_buf.path) do |zip_file|
      # Handle entries one by one
      zip_file.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    expect(per_filename).to have_key("A file")
    expect(per_filename["A file"].bytesize).to eq(file_body.bytesize)
  end

  it "supports unbuffered output with write_buffer_size: 0" do
    output_zip = ->(zip) {
      rng = Random.new(RSpec.configuration.seed)
      200.times do |n|
        zip.write_file("file_#{n}.bin") do |sink|
          sink.write(rng.bytes(10))
        end
      end
    }

    enum = described_class.new(&output_zip)
    output_chunks = []
    enum.each do |some_data|
      output_chunks << some_data.dup
    end
    expect(output_chunks.length).to eq(1)

    enum = described_class.new(write_buffer_size: 0, &output_zip)
    output_chunks = []
    enum.each do |some_data|
      output_chunks << some_data.dup
    end
    expect(output_chunks.length).to be > 100
  end

  it "outputs a Tempfile body which offers to_path" do
    random_bytes = Random.new(RSpec.configuration.seed).bytes(10)
    enum = described_class.new { |zip|
      zip.write_stored_file("test.bin") do |writable|
        writable << random_bytes
      end
    }
    rack_env = {"HTTP_VERSION" => "HTTP/1.0"}
    headers, rack_body = enum.to_headers_and_rack_response_body(rack_env)
    expect(headers["Last-Modified"]).to be_kind_of(String)
    expect(headers["Content-Length"]).to be_kind_of(String)

    tempfile_path = rack_body.to_path
    expect(rack_env["rack.tempfiles"]).not_to be_empty

    tempfile = File.open(tempfile_path, "rb")
    expect(tempfile.size).to be > 0

    output_from_each = StringIO.new.binmode
    rack_body.each { |bytes| output_from_each << bytes }
    expect(output_from_each.size).to eq(tempfile.size)
  end

  it "outputs a Tempfile body which offers to_path" do
    random_bytes = Random.new(RSpec.configuration.seed).bytes(10)
    enum = described_class.new { |zip|
      zip.write_stored_file("test.bin") do |writable|
        writable << random_bytes
      end
    }
    rack_env = {"HTTP_VERSION" => "HTTP/1.0"}
    headers, rack_body = enum.to_headers_and_rack_response_body(rack_env)
    expect(headers["Last-Modified"]).to be_kind_of(String)
    expect(headers["Content-Length"]).to be_kind_of(String)

    tempfile_path = rack_body.to_path
    expect(rack_env["rack.tempfiles"]).not_to be_empty

    tempfile = File.open(tempfile_path, "rb")
    expect(tempfile.size).to be > 0

    output_from_each = StringIO.new.binmode
    rack_body.each { |bytes| output_from_each << bytes }
    expect(output_from_each.size).to eq(tempfile.size)
  end

  it "outputs a chunked body suitable for a chunked HTTP response" do
    random_bytes = Random.new(RSpec.configuration.seed).bytes(10)
    enum = described_class.new { |zip|
      zip.write_stored_file("test.bin") do |writable|
        writable << random_bytes
      end
    }
    rack_env = {}
    headers, chunked_rack_body = enum.to_headers_and_rack_response_body(rack_env)
    expect(headers["Last-Modified"]).to be_kind_of(String)
    expect(headers["Content-Length"]).to be_nil
    expect(headers["Transfer-Encoding"]).to eq("chunked")

    io_output_from_bare_enum = StringIO.new.binmode
    io_output_with_chunked_encoding = StringIO.new.binmode
    enum.each { |bytes| io_output_from_bare_enum << bytes }
    chunked_rack_body.each { |bytes| io_output_with_chunked_encoding << bytes }

    expect(io_output_with_chunked_encoding.size).to be > io_output_from_bare_enum.size

    io_output_from_bare_enum.rewind
    io_output_with_chunked_encoding_decoded = decode_chunked_encoding(io_output_with_chunked_encoding)

    expect(io_output_with_chunked_encoding_decoded.string).to eq(io_output_from_bare_enum.string)
  end

  it "outputs a pre-sized body when a specific content_length: is given" do
    random_bytes = Random.new(RSpec.configuration.seed).bytes(10)
    enum = described_class.new { |zip|
      zip.write_stored_file("test.bin") do |writable|
        writable << random_bytes
      end
    }
    io_output_from_bare_enum = StringIO.new.binmode
    enum.each { |bytes| io_output_from_bare_enum << bytes }

    rack_env = {}
    headers, presized_rack_body = enum.to_headers_and_rack_response_body(rack_env, content_length: io_output_from_bare_enum.size)

    expect(headers["Last-Modified"]).to be_kind_of(String)
    expect(headers["Content-Length"]).to eq(io_output_from_bare_enum.size.to_s)
    expect(headers["Transfer-Encoding"]).to be_nil

    expect(presized_rack_body).to eq(enum) # The enum itself can work as the Rack response body in this case
  end
end
