require_relative "../spec_helper"

# Ractor#join and Ractor#value only exist from Ruby 4.0 onwards, and older Ractor
# implementations are too different to bother with.
describe "ZipKit used from within Ractors" do
  before do
    skip "Ractor#value is not available on this Ruby" unless defined?(Ractor) && Ractor.method_defined?(:value)
    @experimental_warnings = Warning[:experimental]
    Warning[:experimental] = false
  end

  after do
    Warning[:experimental] = @experimental_warnings unless @experimental_warnings.nil?
  end

  let(:war_and_peace_path) { File.expand_path("war-and-peace.txt", __dir__) }

  it "writes ZIPs in multiple Ractors" do
    ractors = 4.times.map do |n|
      Ractor.new(n, war_and_peace_path) do |n, text_path|
        out = +""
        ZipKit::Streamer.open(out, auto_rename_duplicate_filenames: true) do |zip|
          zip.write_file("heuristic-#{n}.txt") { |w| w << "hello from Ractor #{n}\n" * 10_000 }
          zip.write_file("heuristic-random-#{n}.bin") { |w| w << Random.bytes(256 * 1024) }
          zip.write_deflated_file("deflated-#{n}.txt") { |w| File.open(text_path, "rb") { |f| IO.copy_stream(f, w) } }
          zip.write_stored_file("stored-#{n}.bin") { |w| w << ("x" * 1024) }
          zip.write_stored_file("stored-#{n}.bin") { |w| w << ("y" * 1024) }
          zip.add_empty_directory(dirname: "dir-#{n}")

          begin
            zip.write_file("rolled-back-#{n}.txt") { |w| raise "Discard this entry" }
          rescue RuntimeError
          end

          crc = ZipKit::StreamCRC32.from_io(StringIO.new("abc" * 1000))
          compressed = ZipKit::BlockDeflate.deflate_chunk("abc" * 1000) + ZipKit::BlockDeflate::END_MARKER
          zip.add_deflated_entry(filename: "manual-#{n}.txt", compressed_size: compressed.bytesize, uncompressed_size: 3000, crc32: crc)
          zip << compressed
        end
        out
      end
    end

    zips = ractors.map(&:value)
    expect(zips.length).to eq(4)

    zips.each_with_index do |bytes, n|
      entries = ZipKit::FileReader.read_zip_structure(io: StringIO.new(bytes))
      expect(entries.map(&:filename)).to eq([
        "heuristic-#{n}.txt",
        "heuristic-random-#{n}.bin",
        "deflated-#{n}.txt",
        "stored-#{n}.bin",
        "stored-#{n} (1).bin",
        "dir-#{n}/",
        "manual-#{n}.txt"
      ])
      extracted = entries.find { |e| e.filename == "deflated-#{n}.txt" }.extractor_from(StringIO.new(bytes)).extract
      expect(extracted).to eq(File.binread(war_and_peace_path))
      extracted = entries.find { |e| e.filename == "manual-#{n}.txt" }.extractor_from(StringIO.new(bytes)).extract
      expect(extracted).to eq("abc" * 1000)
    end
  end

  it "uses OutputEnumerator, RackChunkedBody, BlockWrite and SizeEstimator in multiple Ractors" do
    ractors = 3.times.map do |n|
      Ractor.new(n) do |n|
        payload = "Payload #{n}" * 512
        predicted_size = ZipKit::SizeEstimator.estimate do |estimator|
          estimator.add_stored_entry(filename: "file-#{n}.txt", size: payload.bytesize, use_data_descriptor: true)
        end

        chunks = []
        body = ZipKit::OutputEnumerator.new(write_buffer_size: 128) do |zip|
          zip.write_stored_file("file-#{n}.txt") { |w| w << payload }
        end
        body.each { |chunk| chunks << chunk }

        chunked = []
        ZipKit::RackChunkedBody.new(chunks).each { |chunk| chunked << chunk }

        blocks = []
        writer = ZipKit::BlockWrite.new { |bytes| blocks << bytes }
        ZipKit::Streamer.open(writer) do |zip|
          zip.write_stored_file("file-#{n}.txt") { |w| w << payload }
        end
        seek_error = begin
          writer.seek(0)
        rescue => e
          e.message
        end

        [predicted_size, chunks.join, chunked.join, blocks.join, seek_error]
      end
    end

    ractors.each_with_index do |ractor, n|
      predicted_size, enumerated, chunked, block_written, seek_error = ractor.value
      expect(enumerated.bytesize).to eq(predicted_size)
      expect(chunked).to end_with("0\r\n\r\n")
      expect(seek_error).to match(/non-rewindable/)
      expect(block_written.bytesize).to eq(predicted_size)
      entries = ZipKit::FileReader.read_zip_structure(io: StringIO.new(enumerated))
      expect(entries.map(&:filename)).to eq(["file-#{n}.txt"])
    end
  end

  it "reads ZIPs in multiple Ractors" do
    zip_paths = 4.times.map do |n|
      tf = ManagedTempfile.new("ractor-read")
      tf.binmode
      # No data descriptors, so that read_zip_straight_ahead can read these too
      deflated = "Deflated in ZIP #{n}\n" * 1000
      stored = "Stored in ZIP #{n}\n" * 100
      compressed = ZipKit::BlockDeflate.deflate_chunk(deflated) + ZipKit::BlockDeflate::END_MARKER
      ZipKit::Streamer.open(tf) do |zip|
        zip.add_deflated_entry(filename: "deflated.txt", compressed_size: compressed.bytesize, uncompressed_size: deflated.bytesize, crc32: Zlib.crc32(deflated))
        zip << compressed
        zip.add_stored_entry(filename: "stored.txt", size: stored.bytesize, crc32: Zlib.crc32(stored))
        zip << stored
        zip.add_empty_directory(dirname: "empty")
      end
      tf.flush
      tf.path
    end

    ractors = zip_paths.map do |path|
      Ractor.new(path.dup.freeze) do |path|
        File.open(path, "rb") do |f|
          from_central_directory = ZipKit::FileReader.read_zip_structure(io: f).map do |entry|
            extracted = entry.filename.end_with?("/") ? "" : entry.extractor_from(f).extract
            [entry.filename, extracted]
          end
          f.rewind
          straight_ahead = ZipKit::FileReader.read_zip_straight_ahead(io: f).map(&:filename)
          [from_central_directory, straight_ahead]
        end
      end
    end
    ractors.each(&:join)

    ractors.each_with_index do |ractor, n|
      from_central_directory, straight_ahead = ractor.value
      expect(from_central_directory).to eq([
        ["deflated.txt", "Deflated in ZIP #{n}\n" * 1000],
        ["stored.txt", "Stored in ZIP #{n}\n" * 100],
        ["empty/", ""]
      ])
      expect(straight_ahead).to eq(["deflated.txt", "stored.txt", "empty/"])
    end
  end
end
