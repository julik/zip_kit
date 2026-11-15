require "test_helper"

class FileReaderTest < TestCase
  context "with a file without EOCD" do
    test "raises the MissingEOCD exception and refuses to read" do
      f = StringIO.new
      10.times { f << ("A" * 1_024) }
      f.rewind

      assert_raises(ZipKit::FileReader::MissingEOCD) { ZipKit::FileReader.read_zip_structure(io: f) }
    end
  end

  describe "read_zip_straight_ahead" do
    test "returns all the entries it can recover" do
      zipfile = StringIO.new
      war_and_peace = File.binread(__dir__ + "/war-and-peace.txt")
      ZipKit::Streamer.open(zipfile) do |zip|
        zip.add_stored_entry filename: "text1.txt",
          crc32: Zlib.crc32(war_and_peace),
          size: war_and_peace.bytesize
        zip << war_and_peace
        zip.add_stored_entry filename: "text2.txt",
          crc32: Zlib.crc32(war_and_peace),
          size: war_and_peace.bytesize
        zip << war_and_peace
        zip.add_stored_entry filename: "text3.txt",
          crc32: Zlib.crc32(war_and_peace),
          size: war_and_peace.bytesize
        zip << war_and_peace
      end
      zipfile.rewind

      recovered_entries = ZipKit::FileReader.read_zip_straight_ahead(io: zipfile)
      assert_equal 3, recovered_entries.length
      recovered_entries.each do |entry|
        assert_equal 0, entry.storage_mode
        assert_equal 496_006, entry.compressed_size
        assert_equal 496_006, entry.uncompressed_size
      end

      first, second, third = recovered_entries
      assert_equal 48, first.compressed_data_offset
      assert_equal 496_102, second.compressed_data_offset
      assert_equal 992_156, third.compressed_data_offset

      recovered_entries.each do |entry|
        zipfile.seek(entry.compressed_data_offset)
        assert_equal war_and_peace[0...5], zipfile.read(5)
      end
    end

    test "recovers an entry that uses Zip64 extra fields" do
      zipfile = StringIO.new
      w = ZipKit::ZipWriter.new
      w.write_local_file_header(io: zipfile,
        filename: "big.bin",
        compressed_size: 0xFFFFFFFFFF,
        uncompressed_size: 0xFFFFFFFFF,
        crc32: 0,
        gp_flags: 0,
        mtime: Time.now,
        storage_mode: 0)
      zipfile.rewind
      recovered_entries = ZipKit::FileReader.read_zip_straight_ahead(io: zipfile)
      assert_equal 1, recovered_entries.length
      entry = recovered_entries.shift
      assert_equal 0xFFFFFFFFFF, entry.compressed_size
    end

    test "raises when an entry uses a data descriptor" do
      zipfile = StringIO.new
      ZipKit::Streamer.open(zipfile) do |zip|
        zip.write_deflated_file("war-and-peace.txt") do |sink|
          sink << File.read(__dir__ + "/war-and-peace.txt")
        end
      end
      zipfile.rewind

      assert_raises(ZipKit::FileReader::UnsupportedFeature) { ZipKit::FileReader.read_zip_straight_ahead(io: zipfile) }
    end
  end

  context "with a ZIP file where the size of the central directory is recorded incorrectly, and has a wrong value" do
    test "is still able to read the entries" do
      # Purposefully create a ZIP that we will damage after
      zipfile = StringIO.new
      tolstoy = File.read(__dir__ + "/war-and-peace.txt")
      tolstoy.force_encoding(Encoding::BINARY)

      # Make a one-off Writer that corrupts the size of the central directory
      # and says there is more data in it than there actually is
      evil_writer_class = Class.new(ZipKit::ZipWriter) do
        def write_end_of_central_directory(**kwargs)
          # Pretend there has to be more data
          kwargs[:central_directory_size] = kwargs[:central_directory_size] + 64
          super
        end
      end

      ZipKit::Streamer.open(zipfile, writer: evil_writer_class.new) do |zip|
        zip.write_deflated_file("text-1.txt") { |sink| sink << tolstoy }
        zip.write_deflated_file("text-2.txt") { |sink| sink << tolstoy }
      end

      # Find the start of the EOCD record (signature, then the information
      # about disk numbers and the information about the file counts
      eocd_start_marker = [0x06054b50, 0, 0, 2, 2].pack("Vvvvv")
      eocd_offset = zipfile.string.index(eocd_start_marker)
      refute_nil eocd_offset

      # Seek to the offset where the central directory size is going to be
      # (just after the string we looked for)
      zipfile.seek(eocd_offset + eocd_start_marker.bytesize)
      # and overwrite it.
      zipfile.write([118].pack("V"))
      zipfile.rewind

      entries = ZipKit::FileReader.read_zip_structure(io: zipfile)

      assert_equal 2, entries.length
    end
  end

  context "with an end-to-end ZIP file to read" do
    test "reads and uncompresses the file written deflated with data descriptors" do
      zipfile = StringIO.new
      tolstoy = File.read(__dir__ + "/war-and-peace.txt")
      tolstoy.force_encoding(Encoding::BINARY)

      ZipKit::Streamer.open(zipfile) do |zip|
        zip.write_deflated_file("war-and-peace.txt") do |sink|
          sink << tolstoy
        end
      end

      entries = ZipKit::FileReader.read_zip_structure(io: zipfile)
      assert_equal 1, entries.length

      entry = entries.first

      readback = +""
      reader = entry.extractor_from(zipfile)
      readback << reader.extract(10) until reader.eof?

      assert_equal tolstoy.bytesize, readback.bytesize
      assert_equal tolstoy[0..10], readback[0..10]
      assert_equal tolstoy[-10..], readback[-10..]
    end

    test "performs local file header reads by default" do
      zipfile = StringIO.new
      tolstoy = File.read(__dir__ + "/war-and-peace.txt")
      tolstoy.force_encoding(Encoding::BINARY)

      ZipKit::Streamer.open(zipfile) do |zip|
        40.times do |i|
          zip.write_deflated_file(format("war-and-peace-%d.txt", i)) { |sink| sink << tolstoy }
        end
      end
      zipfile.rewind

      read_monitor = ReadMonitor.new(zipfile)
      _entries = ZipKit::FileReader.read_zip_structure(io: read_monitor, read_local_headers: true)
      assert_equal 44, read_monitor.num_reads
    end

    test "performs local file header reads when `read_local_headers` is set to true" do
      zipfile = StringIO.new
      tolstoy = File.read(__dir__ + "/war-and-peace.txt")
      tolstoy.force_encoding(Encoding::BINARY)

      ZipKit::Streamer.open(zipfile) do |zip|
        40.times do |i|
          zip.write_deflated_file(format("war-and-peace-%d.txt", i)) { |sink| sink << tolstoy }
        end
      end
      zipfile.rewind

      read_monitor = ReadMonitor.new(zipfile)
      entries = ZipKit::FileReader.read_zip_structure(io: read_monitor, read_local_headers: true)
      assert_equal 44, read_monitor.num_reads

      assert_equal 40, entries.length
      entry = entries.first
      assert_predicate entry, :known_offset?
    end

    test "performs a limited number of reads when `read_local_headers` is set to false" do
      zipfile = StringIO.new
      tolstoy = File.read(__dir__ + "/war-and-peace.txt")
      tolstoy.force_encoding(Encoding::BINARY)

      ZipKit::Streamer.open(zipfile) do |zip|
        40.times do |i|
          zip.write_deflated_file(format("war-and-peace-%d.txt", i)) { |sink| sink << tolstoy }
        end
      end
      zipfile.rewind
      read_monitor = ReadMonitor.new(zipfile)

      entries = ZipKit::FileReader.read_zip_structure(io: read_monitor, read_local_headers: false)

      assert_equal 4, read_monitor.num_reads
      assert_equal 40, entries.length
      entry = entries.first
      refute_predicate entry, :known_offset?
      error = assert_raises(ZipKit::FileReader::LocalHeaderPending) { entry.compressed_data_offset }
      assert_match(/read/, error.message)
    end

    test "reads the file written stored with data descriptors" do
      zipfile = StringIO.new
      tolstoy = File.binread(__dir__ + "/war-and-peace.txt")
      ZipKit::Streamer.open(zipfile) do |zip|
        zip.write_stored_file("war-and-peace.txt") do |sink|
          sink << tolstoy
        end
      end

      entries = ZipKit::FileReader.read_zip_structure(io: zipfile)
      assert_equal 1, entries.length

      entry = entries.first

      readback = entry.extractor_from(zipfile).extract
      assert_equal tolstoy.bytesize, readback.bytesize
      assert_equal tolstoy[0..10], readback[0..10]
    end
  end

  describe "#get_compressed_data_offset" do
    def file_reader
      @file_reader ||= ZipKit::FileReader.new
    end

    test "reads the offset for an entry having Zip64 extra fields" do
      w = ZipKit::ZipWriter.new
      out = StringIO.new
      out << Random.new.bytes(7_656_177)
      w.write_local_file_header(io: out,
        filename: "some file",
        compressed_size: 0xFFFFFFFF + 5,
        uncompressed_size: 0xFFFFFFFFF,
        crc32: 123,
        gp_flags: 4,
        mtime: Time.now,
        storage_mode: 8)

      out.rewind

      compressed_data_offset = file_reader.get_compressed_data_offset(io: out,
        local_file_header_offset: 7_656_177)
      assert_equal 7_656_245, compressed_data_offset
    end

    test "reads the offset for an entry having a long name" do
      w = ZipKit::ZipWriter.new
      out = StringIO.new
      out << Random.new.bytes(7)
      w.write_local_file_header(io: out,
        filename: "This is a file with a ridiculously long name.doc",
        compressed_size: 10,
        uncompressed_size: 15,
        crc32: 123,
        gp_flags: 4,
        mtime: Time.now,
        storage_mode: 8)

      out.rewind

      compressed_data_offset = file_reader.get_compressed_data_offset(io: out,
        local_file_header_offset: 7)
      assert_equal 94, compressed_data_offset
    end

    test "reads the offset for an entry whose name does not fit into the initial local header read" do
      w = ZipKit::ZipWriter.new
      out = StringIO.new
      out << Random.new.bytes(7)
      filename = "x" * 0xFFFF
      w.write_local_file_header(io: out,
        filename: filename,
        compressed_size: 10,
        uncompressed_size: 15,
        crc32: 123,
        gp_flags: 4,
        mtime: Time.now,
        storage_mode: 8)
      out << "0123456789"

      out.rewind

      compressed_data_offset = file_reader.get_compressed_data_offset(io: out,
        local_file_header_offset: 7)
      assert_equal 7 + 30 + 0xFFFF + 9, compressed_data_offset

      out.seek(7)
      entry = file_reader.read_local_file_header(io: out)
      assert_equal 0xFFFF, entry.filename.bytesize
      assert_equal 7 + 30 + 0xFFFF + 9, entry.compressed_data_offset
    end

    test "raises a ReadError when the local header is truncated past the initial read" do
      w = ZipKit::ZipWriter.new
      out = StringIO.new
      w.write_local_file_header(io: out,
        filename: "x" * 8000,
        compressed_size: 10,
        uncompressed_size: 15,
        crc32: 123,
        gp_flags: 4,
        mtime: Time.now,
        storage_mode: 8)
      truncated = StringIO.new(out.string.byteslice(0, 6000))

      assert_raises(ZipKit::FileReader::ReadError) do
        file_reader.read_local_file_header(io: truncated)
      end
    end
  end

  test "is able to latch to the EOCD location even if the signature for the EOCD record appears all over the ZIP" do
    # A VERY evil ZIP file which has this signature all over
    eocd_sig = [0x06054b50].pack("V")
    evil_str = "#{eocd_sig} and #{eocd_sig}"

    z = StringIO.new
    w = ZipKit::ZipWriter.new
    w.write_local_file_header(io: z,
      filename: evil_str,
      compressed_size: evil_str.bytesize,
      uncompressed_size: evil_str.bytesize,
      crc32: 0x06054b50,
      gp_flags: 0,
      mtime: Time.now,
      storage_mode: 0)
    z << evil_str
    where = z.tell
    w.write_central_directory_file_header(io: z,
      local_file_header_location: 0,
      gp_flags: 0,
      storage_mode: 0,
      filename: evil_str,
      compressed_size: evil_str.bytesize,
      uncompressed_size: evil_str.bytesize,
      mtime: Time.now,
      crc32: 0x06054b50)
    w.write_end_of_central_directory(io: z,
      start_of_central_directory_location: where,
      central_directory_size: z.tell - where,
      num_files_in_archive: 1,
      comment: evil_str)

    z.rewind
    entries = ZipKit::FileReader.read_zip_structure(io: z)
    assert_equal 1, entries.length
  end

  test "can handle a Zip64 central directory fields that only contains the required fields (substitutes for standard fields)" do
    # In this example central directory, 2 entries contain Zip64 extra where
    # only the local header offset is set (8 bytes each)
    # This is the exceptional case where we have to poke at a private method directly
    File.open(__dir__ + "/cdir_entry_with_partial_use_of_zip64_extra_fields.bin", "rb") do |f|
      reader = ZipKit::FileReader.new
      entry = reader.send(:read_cdir_entry, f)
      assert_equal 4_312_401_349, entry.local_file_header_offset
      assert_equal "Motorhead - Ace Of Spades.srt", entry.filename
      assert_equal 69_121, entry.compressed_size
      assert_equal 69_121, entry.uncompressed_size
    end
  end
end
