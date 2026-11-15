require "test_helper"

class ZipWriterTest < TestCase
  def zip_writer
    @zip_writer ||= ZipKit::ZipWriter.new
  end

  class ByteReader < Struct.new(:io)
    def initialize(io)
      super.tap { io.rewind }
    end

    def read_1b
      read_n(1).unpack1("C")
    end

    def read_2b
      read_n(2).unpack1("v")
    end

    def read_2c
      read_n(2).unpack1("CC")
    end

    def read_4b
      read_n(4).unpack1("V")
    end

    def read_4b_signed
      read_n(4).unpack1("l<")
    end

    def read_8b
      read_n(8).unpack1("Q<")
    end

    def read_n(n)
      io.read(n).tap do |r|
        raise "Expected to read #{n} bytes, but read() returned nil" if r.nil?
        raise "Expected to read #{n} bytes, but read #{r.bytesize} instead" if r.bytesize != n
      end
    end

    # For conveniently going to a specific signature
    def seek_to_start_of_signature(signature)
      io.rewind
      signature_encoded = [signature].pack("V")
      idx = io.read.index(signature_encoded)
      raise "Could not find the signature #{signature} in the buffer" unless idx
      io.seek(idx, IO::SEEK_SET)
    end
  end

  describe "#write_local_file_header" do
    test "writes the local file header for an entry that does not require Zip64" do
      buf = StringIO.new
      mtime = Time.utc(2016, 7, 17, 13, 48)

      zip_writer = ZipKit::ZipWriter.new
      zip_writer.write_local_file_header(io: buf,
        gp_flags: 12,
        crc32: 456,
        compressed_size: 768,
        uncompressed_size: 901,
        mtime: mtime,
        filename: "foo.bin",
        storage_mode: 8)

      br = ByteReader.new(buf)
      assert_equal 0x04034b50, br.read_4b # Signature
      assert_equal 20, br.read_2b # Version needed to extract
      assert_equal 12, br.read_2b # gp flags
      assert_equal 8, br.read_2b # storage mode
      assert_equal 28_160, br.read_2b # DOS time
      assert_equal 18_673, br.read_2b # DOS date
      assert_equal 456, br.read_4b # CRC32
      assert_equal 768, br.read_4b # compressed size
      assert_equal 901, br.read_4b # uncompressed size
      assert_equal 7, br.read_2b # filename size
      assert_equal 9, br.read_2b # extra fields size

      assert_equal "foo.bin", br.read_n(7) # extra fields size

      assert_equal 0x5455, br.read_2b # Extended timestamp extra tag
      assert_equal 5, br.read_2b # Size of the timestamp extra
      assert_equal 1, br.read_1b # The timestamp flag, with only the lowest bit set

      ext_mtime = br.read_4b_signed
      assert_equal 1_468_763_280, ext_mtime # The mtime encoded as a 4byte uint

      parsed_time = Time.at(ext_mtime)
      assert_equal 2_016, parsed_time.year
    end

    test 'writes the local file header for an entry that does require Zip64 based \
        on uncompressed size (with the Zip64 extra)' do
      buf = StringIO.new
      mtime = Time.utc(2016, 7, 17, 13, 48)

      zip_writer = ZipKit::ZipWriter.new
      zip_writer.write_local_file_header(io: buf,
        gp_flags: 12,
        crc32: 456,
        compressed_size: 768,
        uncompressed_size: 0xFFFFFFFF + 1,
        mtime: mtime,
        filename: "foo.bin",
        storage_mode: 8)

      br = ByteReader.new(buf)
      assert_equal 0x04034b50, br.read_4b # Signature
      assert_equal 45, br.read_2b # Version needed to extract
      assert_equal 12, br.read_2b # gp flags
      assert_equal 8, br.read_2b # storage mode
      assert_equal 28_160, br.read_2b # DOS time
      assert_equal 18_673, br.read_2b # DOS date
      assert_equal 456, br.read_4b # CRC32
      assert_equal 0xFFFFFFFF, br.read_4b # compressed size
      assert_equal 0xFFFFFFFF, br.read_4b # uncompressed size
      assert_equal 7, br.read_2b # filename size
      assert_equal 29, br.read_2b # extra fields size (Zip64 + extended timestamp)
      assert_equal "foo.bin", br.read_n(7) # extra fields size

      refute_predicate buf, :eof?

      assert_equal 1, br.read_2b # Zip64 extra tag
      assert_equal 16, br.read_2b # Size of the Zip64 extra payload
      assert_equal 0xFFFFFFFF + 1, br.read_8b # uncompressed size
      assert_equal 768, br.read_8b # compressed size
    end

    test 'writes the local file header for an entry that does require Zip64 based \
        on compressed size (with the Zip64 extra)' do
      buf = StringIO.new
      mtime = Time.utc(2016, 7, 17, 13, 48)

      zip_writer = ZipKit::ZipWriter.new
      zip_writer.write_local_file_header(io: buf,
        gp_flags: 12,
        crc32: 456,
        compressed_size: 0xFFFFFFFF + 1,
        uncompressed_size: 768,
        mtime: mtime,
        filename: "foo.bin",
        storage_mode: 8)

      br = ByteReader.new(buf)
      assert_equal 0x04034b50, br.read_4b # Signature
      assert_equal 45, br.read_2b # Version needed to extract
      assert_equal 12, br.read_2b # gp flags
      assert_equal 8, br.read_2b # storage mode
      assert_equal 28_160, br.read_2b # DOS time
      assert_equal 18_673, br.read_2b # DOS date
      assert_equal 456, br.read_4b # CRC32
      assert_equal 0xFFFFFFFF, br.read_4b # compressed size
      assert_equal 0xFFFFFFFF, br.read_4b # uncompressed size
      assert_equal 7, br.read_2b # filename size
      assert_equal 29, br.read_2b # extra fields size
      assert_equal "foo.bin", br.read_n(7) # extra fields size

      refute_predicate buf, :eof?

      assert_equal 1, br.read_2b # Zip64 extra tag
      assert_equal 16, br.read_2b # Size of the Zip64 extra payload
      assert_equal 768, br.read_8b # uncompressed size
      assert_equal 0xFFFFFFFF + 1, br.read_8b # compressed size
    end
  end

  describe "with extended_timestamp: false" do
    test "writes the local file header without any extra fields" do
      buf = StringIO.new
      zip_writer.write_local_file_header(io: buf,
        gp_flags: 0,
        crc32: 456,
        compressed_size: 20,
        uncompressed_size: 20,
        mtime: Time.utc(2016, 7, 17, 13, 48),
        filename: "mimetype",
        storage_mode: 0,
        extended_timestamp: false)

      br = ByteReader.new(buf)
      br.read_n(26)
      assert_equal 8, br.read_2b # filename size
      assert_equal 0, br.read_2b # extra fields size
      assert_equal "mimetype", br.read_n(8)
      assert_equal "", buf.read # nothing after the filename
    end

    test "still writes the Zip64 extra field into the local file header when the entry needs it" do
      buf = StringIO.new
      zip_writer.write_local_file_header(io: buf,
        gp_flags: 0,
        crc32: 456,
        compressed_size: 0xFFFFFFFF + 1,
        uncompressed_size: 0xFFFFFFFF + 1,
        mtime: Time.utc(2016, 7, 17, 13, 48),
        filename: "foo.bin",
        storage_mode: 8,
        extended_timestamp: false)

      br = ByteReader.new(buf)
      br.read_n(28)
      assert_equal 20, br.read_2b # extra fields size, just the Zip64 one
      br.read_n(7)
      assert_equal 1, br.read_2b # Zip64 extra tag
    end

    test "writes the central directory file header without any extra fields" do
      buf = StringIO.new
      zip_writer.write_central_directory_file_header(io: buf,
        local_file_header_location: 0,
        gp_flags: 0,
        storage_mode: 0,
        compressed_size: 20,
        uncompressed_size: 20,
        mtime: Time.utc(2016, 2, 2, 14, 0),
        crc32: 89_765,
        filename: "mimetype",
        extended_timestamp: false)

      br = ByteReader.new(buf)
      br.read_n(28)
      assert_equal 8, br.read_2b # filename length
      assert_equal 0, br.read_2b # extra field length
      br.read_n(14)
      assert_equal "mimetype", br.read_n(8)
      assert_equal "", buf.read # nothing after the filename
    end
  end

  describe "#write_data_descriptor" do
    test "writes 4-byte sizes into the data descriptor for standard file sizes" do
      buf = StringIO.new

      zip_writer.write_data_descriptor(io: buf,
        crc32: 123,
        compressed_size: 89_821,
        uncompressed_size: 990_912)

      br = ByteReader.new(buf)
      assert_equal 0x08074b50, br.read_4b # Signature
      assert_equal 123, br.read_4b # CRC32
      assert_equal 89_821, br.read_4b # compressed size
      assert_equal 990_912, br.read_4b # uncompressed size
      assert_predicate buf, :eof?
    end

    test "writes 8-byte sizes into the data descriptor for Zip64 compressed file size" do
      buf = StringIO.new

      zip_writer.write_data_descriptor(io: buf,
        crc32: 123,
        compressed_size: 0xFFFFFFFF + 1,
        uncompressed_size: 990_912)

      br = ByteReader.new(buf)
      assert_equal 0x08074b50, br.read_4b # Signature
      assert_equal 123, br.read_4b # CRC32
      assert_equal 0xFFFFFFFF + 1, br.read_8b # compressed size
      assert_equal 990_912, br.read_8b # uncompressed size
      assert_predicate buf, :eof?
    end

    test "writes 8-byte sizes into the data descriptor for Zip64 uncompressed file size" do
      buf = StringIO.new

      zip_writer.write_data_descriptor(io: buf,
        crc32: 123,
        compressed_size: 123,
        uncompressed_size: 0xFFFFFFFF + 1)

      br = ByteReader.new(buf)
      assert_equal 0x08074b50, br.read_4b # Signature
      assert_equal 123, br.read_4b # CRC32
      assert_equal 123, br.read_8b # compressed size
      assert_equal 0xFFFFFFFF + 1, br.read_8b # uncompressed size
      assert_predicate buf, :eof?
    end
  end

  describe "#write_central_directory_file_header" do
    test "writes the file header for a small-ish entry" do
      buf = StringIO.new

      zip_writer.write_central_directory_file_header(io: buf,
        local_file_header_location: 898_921,
        gp_flags: 555,
        storage_mode: 23,
        compressed_size: 901,
        uncompressed_size: 909_102,
        mtime: Time.utc(2016, 2, 2, 14, 0),
        crc32: 89_765,
        filename: "a-file.txt")

      br = ByteReader.new(buf)
      assert_equal 0x02014b50, br.read_4b # Central directory entry sig
      assert_equal 820, br.read_2b # version made by
      assert_equal 20, br.read_2b # version need to extract
      assert_equal 555, br.read_2b # general purpose bit flag (explicitly
      # set to bogus value to ensure we pass it through)
      assert_equal 23, br.read_2b # compression method (explicitly set to bogus value)
      assert_equal 28_672, br.read_2b # last mod file time
      assert_equal 18_498, br.read_2b # last mod file date
      assert_equal 89_765, br.read_4b # crc32
      assert_equal 901, br.read_4b # compressed size
      assert_equal 909_102, br.read_4b # uncompressed size
      assert_equal 10, br.read_2b # filename length
      assert_equal 9, br.read_2b # extra field length
      assert_equal 0, br.read_2b # file comment
      assert_equal 0, br.read_2b # disk number, must be blanked to the
      # maximum value because of The Unarchiver bug
      assert_equal 0, br.read_2b # internal file attributes
      assert_equal 2_175_008_768, br.read_4b # external file attributes
      assert_equal 898_921, br.read_4b # relative offset of local header
      assert_equal "a-file.txt", br.read_n(10) # the filename
    end

    test "writes the file header with custom UNIX permissions" do
      buf = StringIO.new

      zip_writer.write_central_directory_file_header(io: buf,
        local_file_header_location: 898_921,
        gp_flags: 555,
        storage_mode: 23,
        compressed_size: 901,
        uncompressed_size: 909_102,
        mtime: Time.utc(2016, 2, 2, 14, 0),
        crc32: 89_765,
        filename: "a-file.txt",
        unix_permissions: 0o633)

      br = ByteReader.new(buf)
      assert_equal 0x02014b50, br.read_4b # Central directory entry sig
      assert_equal 820, br.read_2b # version made by
      assert_equal 20, br.read_2b # version need to extract
      assert_equal 555, br.read_2b # general purpose bit flag (explicitly
      # set to bogus value to ensure we pass it through)
      assert_equal 23, br.read_2b # compression method (explicitly set to bogus value)
      assert_equal 28_672, br.read_2b # last mod file time
      assert_equal 18_498, br.read_2b # last mod file date
      assert_equal 89_765, br.read_4b # crc32
      assert_equal 901, br.read_4b # compressed size
      assert_equal 909_102, br.read_4b # uncompressed size
      assert_equal 10, br.read_2b # filename length
      assert_equal 9, br.read_2b # extra field length
      assert_equal 0, br.read_2b # file comment
      assert_equal 0, br.read_2b # disk number, must be blanked to the
      # maximum value because of The Unarchiver bug
      assert_equal 0, br.read_2b # internal file attributes
      assert_equal 2_174_418_944, br.read_4b # external file attributes
      assert_equal 898_921, br.read_4b # relative offset of local header
      assert_equal "a-file.txt", br.read_n(10) # the filename
    end

    test "writes the file header for an entry that contains an empty directory" do
      buf = StringIO.new

      zip_writer.write_central_directory_file_header(io: buf,
        local_file_header_location: 898_921,
        gp_flags: 555,
        storage_mode: 23,
        compressed_size: 0,
        uncompressed_size: 0,
        mtime: Time.utc(2016, 2, 2, 14, 0),
        crc32: 0,
        filename: "directory/")

      br = ByteReader.new(buf)
      assert_equal 0x02014b50, br.read_4b # Central directory entry sig
      assert_equal 820, br.read_2b # version made by
      assert_equal 20, br.read_2b # version need to extract
      assert_equal 555, br.read_2b # general purpose bit flag (explicitly
      # set to bogus value to ensure we pass it through)
      assert_equal 23, br.read_2b # compression method (explicitly set to bogus value)
      assert_equal 28_672, br.read_2b # last mod file time
      assert_equal 18_498, br.read_2b # last mod file date
      assert_equal 0, br.read_4b # crc32
      assert_equal 0, br.read_4b # compressed size
      assert_equal 0, br.read_4b # uncompressed size
      assert_equal 10, br.read_2b # filename length
      assert_equal 9, br.read_2b # extra field length
      assert_equal 0, br.read_2b # file comment
      assert_equal 0, br.read_2b # disk number, must be blanked to the
      # maximum value because of The Unarchiver bug
      assert_equal 0, br.read_2b # internal file attributes
      assert_equal 1_106_051_072, br.read_4b # external file attributes
      assert_equal 898_921, br.read_4b # relative offset of local header
      assert_equal "directory/", br.read_n(10) # the filename
    end

    test "writes the file header for an entry that contains an empty directory with custom UNIX permissions" do
      buf = StringIO.new

      zip_writer.write_central_directory_file_header(io: buf,
        local_file_header_location: 898_921,
        gp_flags: 555,
        storage_mode: 23,
        compressed_size: 0,
        uncompressed_size: 0,
        mtime: Time.utc(2016, 2, 2, 14, 0),
        crc32: 0,
        filename: "directory/",
        unix_permissions: 0o777)

      br = ByteReader.new(buf)
      assert_equal 0x02014b50, br.read_4b # Central directory entry sig
      assert_equal 820, br.read_2b # version made by
      assert_equal 20, br.read_2b # version need to extract
      assert_equal 555, br.read_2b # general purpose bit flag (explicitly
      # set to bogus value to ensure we pass it through)
      assert_equal 23, br.read_2b # compression method (explicitly set to bogus value)
      assert_equal 28_672, br.read_2b # last mod file time
      assert_equal 18_498, br.read_2b # last mod file date
      assert_equal 0, br.read_4b # crc32
      assert_equal 0, br.read_4b # compressed size
      assert_equal 0, br.read_4b # uncompressed size
      assert_equal 10, br.read_2b # filename length
      assert_equal 9, br.read_2b # extra field length
      assert_equal 0, br.read_2b # file comment
      assert_equal 0, br.read_2b # disk number, must be blanked to the
      # maximum value because of The Unarchiver bug
      assert_equal 0, br.read_2b # internal file attributes
      assert_equal 1_107_230_720, br.read_4b # external file attributes
      assert_equal 898_921, br.read_4b # relative offset of local header
      assert_equal "directory/", br.read_n(10) # the filename
    end

    test 'writes the file header for an entry that requires Zip64 extra because of \
        the uncompressed size' do
      buf = StringIO.new

      zip_writer.write_central_directory_file_header(io: buf,
        local_file_header_location: 898_921,
        gp_flags: 555,
        storage_mode: 23,
        compressed_size: 901,
        uncompressed_size: 0xFFFFFFFFF + 3,
        mtime: Time.utc(2016, 2, 2, 14, 0),
        crc32: 89_765,
        filename: "a-file.txt")

      br = ByteReader.new(buf)
      assert_equal 0x02014b50, br.read_4b # Central directory entry sig
      assert_equal 820, br.read_2b # version made by
      assert_equal 45, br.read_2b # version need to extract
      assert_equal 555, br.read_2b # general purpose bit flag
      # (explicitly set to bogus value
      # to ensure we pass it through)
      assert_equal 23, br.read_2b # compression method (explicitly
      # set to bogus value)
      assert_equal 28_672, br.read_2b # last mod file time
      assert_equal 18_498, br.read_2b # last mod file date
      assert_equal 89_765, br.read_4b # crc32
      assert_equal 0xFFFFFFFF, br.read_4b # compressed size
      assert_equal 0xFFFFFFFF, br.read_4b # uncompressed size
      assert_equal 10, br.read_2b # filename length
      assert_equal 41, br.read_2b # extra field length
      assert_equal 0, br.read_2b # file comment
      assert_equal 0xFFFF, br.read_2b # disk number, must be blanked
      # to the maximum value because
      # of The Unarchiver bug
      assert_equal 0, br.read_2b # internal file attributes
      assert_equal 2_175_008_768, br.read_4b # external file attributes
      assert_equal 0xFFFFFFFF, br.read_4b # relative offset of local header
      assert_equal "a-file.txt", br.read_n(10) # the filename

      refute_predicate buf, :eof?
      assert_equal 1, br.read_2b # Zip64 extra tag
      assert_equal 28, br.read_2b # Size of the Zip64 extra payload
      assert_equal 0xFFFFFFFFF + 3, br.read_8b # uncompressed size
      assert_equal 901, br.read_8b # compressed size
      assert_equal 898_921, br.read_8b # local file header location
    end

    test 'writes the file header for an entry that requires Zip64 extra because of \
        the compressed size' do
      buf = StringIO.new

      zip_writer.write_central_directory_file_header(io: buf,
        local_file_header_location: 898_921,
        gp_flags: 555,
        storage_mode: 23,
        compressed_size: 0xFFFFFFFFF + 3,
        # the worst compression scheme in the universe
        uncompressed_size: 901,
        mtime: Time.utc(2016, 2, 2, 14, 0),
        crc32: 89_765,
        filename: "a-file.txt")

      br = ByteReader.new(buf)
      assert_equal 0x02014b50, br.read_4b # Central directory entry sig
      assert_equal 820, br.read_2b # version made by
      assert_equal 45, br.read_2b # version need to extract
      assert_equal 555, br.read_2b # general purpose bit flag (explicitly
      # set to bogus value to ensure we pass it through)
      assert_equal 23, br.read_2b # compression method (explicitly set to bogus value)
      assert_equal 28_672, br.read_2b # last mod file time
      assert_equal 18_498, br.read_2b # last mod file date
      assert_equal 89_765, br.read_4b # crc32
      assert_equal 0xFFFFFFFF, br.read_4b # compressed size
      assert_equal 0xFFFFFFFF, br.read_4b # uncompressed size
      assert_equal 10, br.read_2b # filename length
      assert_equal 41, br.read_2b # extra field length
      assert_equal 0, br.read_2b # file comment
      assert_equal 0xFFFF, br.read_2b # disk number, must be blanked to the
      # maximum value because of The Unarchiver bug
      assert_equal 0, br.read_2b # internal file attributes
      assert_equal 2_175_008_768, br.read_4b # external file attributes
      assert_equal 0xFFFFFFFF, br.read_4b # relative offset of local header
      assert_equal "a-file.txt", br.read_n(10) # the filename

      refute_predicate buf, :eof?
      assert_equal 1, br.read_2b # Zip64 extra tag
      assert_equal 28, br.read_2b # Size of the Zip64 extra payload
      assert_equal 901, br.read_8b # uncompressed size
      assert_equal 0xFFFFFFFFF + 3, br.read_8b # compressed size
      assert_equal 898_921, br.read_8b # local file header location
    end

    test 'writes the file header for an entry that requires Zip64 extra because of \
        the local file header offset being beyound 4GB' do
      buf = StringIO.new

      zip_writer.write_central_directory_file_header(io: buf,
        local_file_header_location: 0xFFFFFFFFF + 1,
        gp_flags: 555,
        storage_mode: 23,
        compressed_size: 8_981,
        # the worst compression scheme in the universe
        uncompressed_size: 819_891,
        mtime: Time.utc(2016, 2, 2, 14, 0),
        crc32: 89_765,
        filename: "a-file.txt")

      br = ByteReader.new(buf)
      assert_equal 0x02014b50, br.read_4b # Central directory entry sig
      assert_equal 820, br.read_2b # version made by
      assert_equal 45, br.read_2b # version need to extract
      assert_equal 555, br.read_2b # general purpose bit flag (explicitly
      # set to bogus value to ensure we pass it through)
      assert_equal 23, br.read_2b # compression method (explicitly set to bogus value)
      assert_equal 28_672, br.read_2b # last mod file time
      assert_equal 18_498, br.read_2b # last mod file date
      assert_equal 89_765, br.read_4b # crc32
      assert_equal 0xFFFFFFFF, br.read_4b # compressed size
      assert_equal 0xFFFFFFFF, br.read_4b # uncompressed size
      assert_equal 10, br.read_2b # filename length
      assert_equal 41, br.read_2b # extra field length
      assert_equal 0, br.read_2b # file comment
      assert_equal 0xFFFF, br.read_2b # disk number, must be blanked to the
      # maximum value because of The Unarchiver bug
      assert_equal 0, br.read_2b # internal file attributes
      assert_equal 2_175_008_768, br.read_4b # external file attributes
      assert_equal 0xFFFFFFFF, br.read_4b # relative offset of local header
      assert_equal "a-file.txt", br.read_n(10) # the filename

      refute_predicate buf, :eof?
      assert_equal 1, br.read_2b # Zip64 extra tag
      assert_equal 28, br.read_2b # Size of the Zip64 extra payload
      assert_equal 819_891, br.read_8b # uncompressed size
      assert_equal 8_981, br.read_8b # compressed size
      assert_equal 0xFFFFFFFFF + 1, br.read_8b # local file header location
    end
  end

  describe "#write_end_of_central_directory" do
    test "writes out the EOCD with all markers for a small ZIP file with just a few entries" do
      buf = StringIO.new

      num_files = rand(8..190)
      zip_writer.write_end_of_central_directory(io: buf,
        start_of_central_directory_location: 9_091_211,
        central_directory_size: 9_091,
        num_files_in_archive: num_files)

      br = ByteReader.new(buf)
      assert_equal 0x06054b50, br.read_4b # EOCD signature
      assert_equal 0, br.read_2b # number of this disk
      assert_equal 0, br.read_2b # number of the disk with the EOCD record
      assert_equal num_files, br.read_2b # number of files on this disk
      assert_equal num_files, br.read_2b # number of files in central directory
      # total (for all disks)
      assert_equal 9_091, br.read_4b # size of the central directory (cdir records for all files)
      assert_equal 9_091_211, br.read_4b # start of central directory offset from
      # the beginning of file/disk

      comment_length = br.read_2b
      refute_predicate comment_length, :zero?

      assert_match(/ZipKit/, br.read_n(comment_length))
    end

    test "writes out the custom comment" do
      buf = +""
      comment = "Ohai mate"
      zip_writer.write_end_of_central_directory(io: buf,
        start_of_central_directory_location: 9_091_211,
        central_directory_size: 9_091,
        num_files_in_archive: 4,
        comment: comment)

      size_and_comment = buf[((comment.bytesize + 2) * -1)..]
      comment_size = size_and_comment.unpack1("v")
      assert_equal comment.bytesize, comment_size
    end

    test 'writes out the Zip64 EOCD as well if the central directory is located \
        beyound 4GB in the archive' do
      buf = StringIO.new

      num_files = rand(8..190)
      zip_writer.write_end_of_central_directory(io: buf,
        start_of_central_directory_location: 0xFFFFFFFF + 3,
        central_directory_size: 9091,
        num_files_in_archive: num_files)

      br = ByteReader.new(buf)

      assert_equal 0x06064b50, br.read_4b # Zip64 EOCD signature
      assert_equal 44, br.read_8b # Zip64 EOCD record size
      assert_equal 820, br.read_2b # Version made by
      assert_equal 45, br.read_2b # Version needed to extract
      assert_equal 0, br.read_4b # Number of this disk
      assert_equal 0, br.read_4b # Number of the disk with the Zip64 EOCD record
      assert_equal num_files, br.read_8b # Number of entries in the central
      # directory of this disk
      assert_equal num_files, br.read_8b # Number of entries in the central
      # directories of all disks
      assert_equal 9_091, br.read_8b # Central directory size
      assert_equal 0xFFFFFFFF + 3, br.read_8b # Start of central directory location

      assert_equal 0x07064b50, br.read_4b # Zip64 EOCD locator signature
      assert_equal 0, br.read_4b # Number of the disk with the EOCD locator signature
      assert_equal((0xFFFFFFFF + 3) + 9_091, br.read_8b) # Where the Zip64 EOCD record starts
      assert_equal 1, br.read_4b # Total number of disks

      # Then the usual EOCD record
      assert_equal 0x06054b50, br.read_4b # EOCD signature
      assert_equal 0, br.read_2b # number of this disk
      assert_equal 0, br.read_2b # number of the disk with the EOCD record
      assert_equal 0xFFFF, br.read_2b # number of files on this disk
      assert_equal 0xFFFF, br.read_2b # number of files in central directory
      # total (for all disks)
      assert_equal 0xFFFFFFFF, br.read_4b # size of the central directory
      # (cdir records for all files)
      assert_equal 0xFFFFFFFF, br.read_4b # start of central directory offset
      # from the beginning of file/disk

      comment_length = br.read_2b
      refute_predicate comment_length, :zero?
      assert_match(/ZipKit/, br.read_n(comment_length))
    end

    test "writes out the Zip64 EOCD if the archive has more than 0xFFFF files" do
      buf = StringIO.new

      zip_writer.write_end_of_central_directory(io: buf,
        start_of_central_directory_location: 123,
        central_directory_size: 9_091,
        num_files_in_archive: 0xFFFF + 1)

      br = ByteReader.new(buf)

      assert_equal 0x06064b50, br.read_4b # Zip64 EOCD signature
      br.read_8b
      br.read_2b
      br.read_2b
      br.read_4b
      br.read_4b
      assert_equal 0xFFFF + 1, br.read_8b # Number of entries in the central
      # directory of this disk
      assert_equal 0xFFFF + 1, br.read_8b # Number of entries in the central
      # directories of all disks
    end

    test "writes out the Zip64 EOCD if the central directory size exceeds 0xFFFFFFFF" do
      buf = StringIO.new

      zip_writer.write_end_of_central_directory(io: buf,
        start_of_central_directory_location: 123,
        central_directory_size: 0xFFFFFFFF + 2,
        num_files_in_archive: 5)

      br = ByteReader.new(buf)

      assert_equal 0x06064b50, br.read_4b # Zip64 EOCD signature
      br.read_8b
      br.read_2b
      br.read_2b
      br.read_4b
      br.read_4b
      assert_equal 5, br.read_8b # Number of entries in the central directory of this disk
      assert_equal 5, br.read_8b # Number of entries in the central directories of all disks
    end
  end

  test "can be used in a process which did not load StringIO beforehand" do
    lib_path = File.expand_path("../../lib", __dir__)
    script = <<~RUBY
      File.open(File::NULL, "wb") do |f|
        ZipKit::Streamer.open(f) { |zip| zip.write_stored_file("a.txt") { |sink| sink << "x" } }
      end
      print "ok"
    RUBY
    output = IO.popen([RbConfig.ruby, "--disable-gems", "-I", lib_path, "-rzip_kit", "-e", script], err: [:child, :out], &:read)
    assert_equal "ok", output
  end
end
