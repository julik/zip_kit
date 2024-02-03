require_relative '../spec_helper'

describe ZipTricks::RackBody do
  it 'is usable as a Rack response body, supports each()' do
    output_buf = Tempfile.new('output')

    file_body = Random.new.bytes(1024 * 1024 + 8981)

    body = described_class.new do |zip|
      zip.add_stored_entry(filename: 'A file',
                           size: file_body.bytesize,
                           crc32: Zlib.crc32(file_body))
      zip << file_body
    end

    body.each do |some_data|
      output_buf << some_data
    end

    output_buf.rewind
    expect(output_buf.size).to eq(1_057_714)

    per_filename = {}
    Zip::File.open(output_buf.path) do |zip_file|
      # Handle entries one by one
      zip_file.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    expect(per_filename).to have_key('A file')
    expect(per_filename['A file'].bytesize).to eq(file_body.bytesize)
  end

  it 'outputs a chunked body suitable for a chunked HTTP response' do
    random_bytes = Random.new(RSpec.configuration.seed).bytes(10)
    body = described_class.new do |zip|
      zip.write_stored_file("test.bin") do |writable|
        writable << random_bytes
      end
    end
    chunked_body = body.to_chunked

    io1 = StringIO.new.binmode
    io2 = StringIO.new.binmode
    body.each { |bytes| io1 << bytes }
    chunked_body.each { |bytes| io2 << bytes }

    expect(io2.size).to be > io1.size

    io1.rewind
    io2_decoded = decode_chunked_encoding(io2)

    expect(io2_decoded.string).to eq(io2_decoded.string)
  end

  it 'outputs a body containing a Tempfile for accelerated serving' do
    random_bytes = Random.new(RSpec.configuration.seed).bytes(10)
    body = described_class.new do |zip|
      zip.write_stored_file("test.bin") do |writable|
        writable << random_bytes
      end
    end
    env = {}
    tf_body = body.to_tempfile_body(env)
    expect(env["rack.tempfiles"]).not_to be_empty

    expect(tf_body.size).to be > 0
    expect(tf_body.to_path).to be_kind_of(String)
    expect(tf_body.size).to eq(File.size(tf_body.to_path))
    expect(tf_body.tempfile).to be_binmode

    output_from_bare_enumerator = StringIO.new.binmode
    body.each { |bytes| output_from_bare_enumerator << bytes }

    expect(tf_body.size).to eq(output_from_bare_enumerator.size)
  end
end
