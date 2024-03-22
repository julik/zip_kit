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

  it "provides streaming headers on the object instance" do
    headers = described_class.new.streaming_http_headers
    expect(headers).to be_kind_of(Hash)
    expect(headers["Content-Encoding"]).to eq("identity")
  end

  it "provides streaming headers on the class" do
    headers = described_class.streaming_http_headers
    expect(headers).to be_kind_of(Hash)
    expect(headers["Content-Encoding"]).to eq("identity")
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

  it "outputs an enumerable body suitable for a chunked HTTP response" do
    random_bytes = Random.new(RSpec.configuration.seed).bytes(10)
    enum = described_class.new { |zip|
      zip.write_stored_file("test.bin") do |writable|
        writable << random_bytes
      end
    }
    headers, rack_body = enum.to_headers_and_rack_response_body(nil, anything: nil, content_length: nil)
    expect(headers["Last-Modified"]).to be_kind_of(String)
    expect(headers["Content-Length"]).to be_nil
    expect(headers["Transfer-Encoding"]).to be_nil

    expect(rack_body).to eq(enum)
  end
end
