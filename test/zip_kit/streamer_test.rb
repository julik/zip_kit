require "test_helper"

class StreamerTest < TestCase
  WRITER_METHODS = [
    :write_local_file_header,
    :write_data_descriptor,
    :write_central_directory_file_header,
    :write_end_of_central_directory
  ]

  class FakeZipWriter
    def write_local_file_header(*)
    end

    def write_data_descriptor(*)
    end

    def write_central_directory_file_header(*)
    end

    def write_end_of_central_directory(*)
    end
  end

  # Stands in for the ZipWriter and records the calls it receives, in order, as [method_name, kwargs].
  # Only has the ZipWriter methods, so anything else the Streamer calls on it raises.
  # The block, if given, runs on every call - for when the writer has to act on the `io:`
  class RecordingWriter
    attr_reader :calls

    def initialize(&on_call)
      @calls = []
      @on_call = on_call
    end

    WRITER_METHODS.each do |method_name|
      define_method(method_name) do |**kwargs|
        @calls << [method_name, kwargs]
        @on_call&.call(method_name, kwargs)
        nil
      end
    end

    def called_methods
      @calls.map(&:first)
    end

    def kwargs_of(method_name)
      @calls.select { |(name, _)| name == method_name }.map(&:last)
    end
  end

  # Run each test in a temporady directory, and nuke it afterwards
  def setup
    super
    @wd = Dir.pwd
    @td = Dir.mktmpdir
    Dir.chdir(@td)
  end

  def teardown
    super
  ensure
    Dir.chdir(@wd)
    FileUtils.remove_entry(@td)
  end

  def rewind_after(*ios)
    yield.tap { ios.map(&:rewind) }
  end

  # Measures timings, which other test workers hammering the CPU would skew
  test "has linear performance depending on the file count", parallel: false do
    assert_linear_complexity do |n_files|
      ZipKit::Streamer.open(ZipKit::NullWriter, writer: FakeZipWriter.new) do |w|
        n_files.times do |i|
          w.write_stored_file(format("file_%d", i)) { |body| body << "w" }
        end
      end
    end
  end

  test "raises an InvalidOutput if the given object does not support the methods" do
    assert_raises(ZipKit::Streamer::InvalidOutput) { ZipKit::Streamer.new(nil) }
  end

  test "allows a destination which only supports write()" do
    stream_with_just_write = Object.new
    def stream_with_just_write.write(bytes)
      # noop
    end

    streamer = assert_nothing_raised { ZipKit::Streamer.new(stream_with_just_write) }
    assert_kind_of ZipKit::Streamer, streamer
  end

  test "allows the writer to be injectable" do
    fake_writer = RecordingWriter.new

    ZipKit::Streamer.open(+"", writer: fake_writer) do |zip|
      zip.write_deflated_file("stored.txt") do |sink|
        sink << File.read(__dir__ + "/war-and-peace.txt")
      end
    end

    assert_equal WRITER_METHODS, fake_writer.called_methods
  end

  test "returns the position in the IO at every call" do
    io = StringIO.new
    zip = ZipKit::Streamer.new(io)
    pos = zip.add_deflated_entry(filename: "file.jpg",
      uncompressed_size: 182_919,
      compressed_size: 8_912,
      crc32: 8_912)
    assert_equal io.tell, pos
    assert_equal 47, pos

    retval = zip << Random.new.bytes(8_912)
    assert_equal zip, retval
    assert_equal 8_959, io.tell

    pos = zip.add_stored_entry(filename: "filf.jpg", size: 8_921, crc32: 182_919)
    assert_equal 9006, pos
    zip << Random.new.bytes(8_921)
    assert_equal 17_927, io.tell

    pos = zip.close
    assert_equal io.tell, pos
    assert_equal 18_101, pos
  end

  test "can write and then read the block-deflated files" do
    f = ManagedTempfile.new("raw")
    f.binmode

    rewind_after(f) do
      f << ("A" * 1_024 * 1_024)
      f << Random.new.bytes(1_248)
      f << ("B" * 1_024 * 1_024)
    end

    crc = rewind_after(f) { Zlib.crc32(f.read) }

    compressed_blockwise = StringIO.new
    rewind_after(compressed_blockwise, f) do
      ZipKit::BlockDeflate.deflate_in_blocks_and_terminate(f,
        compressed_blockwise,
        block_size: 1_024)
    end

    # Perform the zipping
    zip_file = ManagedTempfile.new("z")
    zip_file.binmode

    ZipKit::Streamer.open(zip_file) do |zip|
      zip.add_deflated_entry(filename: "compressed-file.bin",
        uncompressed_size: f.size,
        crc32: crc,
        compressed_size: compressed_blockwise.size)
      zip << compressed_blockwise.read
    end
    zip_file.flush

    per_filename = {}
    Zip::File.open(zip_file.path) do |zipfile|
      # Handle entries one by one
      zipfile.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    assert_equal f.size, per_filename["compressed-file.bin"].bytesize
    assert_equal Digest::SHA1.hexdigest(f.read), Digest::SHA1.hexdigest(per_filename["compressed-file.bin"])
  end

  test "can write and then read an empty directory" do
    # Perform the zipping
    zip_file = ManagedTempfile.new("z")
    zip_file.binmode

    ZipKit::Streamer.open(zip_file) do |zip|
      zip.add_empty_directory(dirname: "Tunes")
    end
    zip_file.flush

    per_filename = {}

    Zip::File.open(zip_file.path) do |zipfile|
      # Handle entries one by one
      zipfile.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_raw_input_stream.read
      end
    end

    assert_equal 154, per_filename["Tunes/"].bytesize
  end

  test "can write the data descriptor and updates the last entry as well" do
    out = StringIO.new
    fake_w = RecordingWriter.new

    file_contents = "Some data from file"
    crc = Zlib.crc32("Some data from file")

    ZipKit::Streamer.open(out, writer: fake_w) do |zip|
      zip.add_stored_entry(filename: "somefile.txt", use_data_descriptor: true)
      zip << file_contents
      zip.update_last_entry_and_write_data_descriptor(crc32: crc,
        compressed_size: file_contents.bytesize,
        uncompressed_size: file_contents.bytesize)
    end

    assert_equal WRITER_METHODS, fake_w.called_methods
  end

  test "archives files which can then be read using the usual means with Rubyzip" do
    zip_buf = ManagedTempfile.new("zipp")
    zip_buf.binmode
    output_io = Object.new

    # Only allow the methods we provide in BlockWrite.
    # Will raise an error if other methods are triggered (the ones that
    # might try to rewind the IO).
    output_io.define_singleton_method(:<<) { |data|
      zip_buf << data.to_s.force_encoding(Encoding::BINARY)
    }

    output_io.define_singleton_method(:tell) { zip_buf.tell }
    output_io.define_singleton_method(:pos) { zip_buf.pos }
    output_io.define_singleton_method(:close) {}

    # Generate a couple of random files
    raw_file1 = Random.new.bytes(1024 * 20)
    raw_file2 = Random.new.bytes(1024 * 128)

    # Perform the zipping
    zip = ZipKit::Streamer.new(output_io)
    zip.add_stored_entry(filename: "first-file.bin",
      size: raw_file1.size,
      crc32: Zlib.crc32(raw_file1))
    zip << raw_file1
    zip.add_stored_entry(filename: "second-file.bin",
      size: raw_file2.size,
      crc32: Zlib.crc32(raw_file2))
    zip << raw_file2
    zip.close

    zip_buf.flush

    per_filename = {}
    Zip::File.open(zip_buf.path) do |zip_file|
      # Handle entries one by one
      zip_file.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        # Somehow an empty string gets read
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    assert_equal raw_file1.unpack("C*"), per_filename["first-file.bin"].unpack("C*")
    assert_equal raw_file2.unpack("C*"), per_filename["second-file.bin"].unpack("C*")
  end

  test "sets the general-purpose flag for entries with UTF8 names" do
    zip_buf = ManagedTempfile.new("zipp")
    zip_buf.binmode

    # Generate a couple of random files
    raw_file1 = Random.new.bytes(1_024 * 20)
    raw_file2 = Random.new.bytes(1_024 * 128)

    # Perform the zipping
    zip = ZipKit::Streamer.new(zip_buf)
    zip.add_stored_entry(filename: "first-file.bin",
      size: raw_file1.size,
      crc32: Zlib.crc32(raw_file1))
    zip << raw_file1
    zip.add_stored_entry(filename: "второй-файл.bin",
      size: raw_file2.size,
      crc32: Zlib.crc32(raw_file2))
    IO.copy_stream(StringIO.new(raw_file2), zip)
    zip.close

    zip_buf.flush

    entries = []
    Zip::File.open(zip_buf.path) do |zip_file|
      # Handle entries one by one
      zip_file.each { |entry| entries << entry }
      first_entry, second_entry = entries

      assert_equal 0, first_entry.gp_flags
      assert_equal "first-file.bin", first_entry.name

      # Rubyzip does not properly set the encoding of the entries it reads
      assert_equal 2_048, second_entry.gp_flags
      assert_equal((+"второй-файл.bin").force_encoding(Encoding::BINARY), second_entry.name)
    end
  end

  test "writes the correct archive elements when using data descriptors" do
    out = StringIO.new
    fake_w = RecordingWriter.new { |method_name, kwargs|
      kwargs[:io] << "fake" if method_name == :write_central_directory_file_header
    }

    ZipKit::Streamer.open(out, writer: fake_w) do |z|
      z.write_deflated_file("somefile.txt") do |out|
        out << "Experimental data"
      end
      z.write_stored_file("uncompressed.txt") do |out|
        out << "Some uncompressed data"
      end
    end

    assert_equal [
      :write_local_file_header,
      :write_data_descriptor,
      :write_local_file_header,
      :write_data_descriptor,
      :write_central_directory_file_header,
      :write_central_directory_file_header,
      :write_end_of_central_directory
    ], fake_w.called_methods

    first_local_header, second_local_header = fake_w.kwargs_of(:write_local_file_header)
    first_data_descriptor, second_data_descriptor = fake_w.kwargs_of(:write_data_descriptor)
    first_cdir_header, second_cdir_header = fake_w.kwargs_of(:write_central_directory_file_header)
    eocd = fake_w.kwargs_of(:write_end_of_central_directory).first

    assert_equal 8, first_local_header[:storage_mode]
    assert_predicate first_local_header[:crc32], :zero?
    assert_equal "somefile.txt", first_local_header[:filename]

    assert_equal 2729945713, first_data_descriptor[:crc32]
    assert_equal 19, first_data_descriptor[:compressed_size]
    assert_equal 17, first_data_descriptor[:uncompressed_size]

    assert_equal 0, second_local_header[:storage_mode]
    assert_predicate second_local_header[:crc32], :zero?
    assert_equal "uncompressed.txt", second_local_header[:filename]

    assert_equal 1550572917, second_data_descriptor[:crc32]
    assert_equal 22, second_data_descriptor[:compressed_size]
    assert_equal 22, second_data_descriptor[:uncompressed_size]

    assert_equal 0, first_cdir_header[:local_file_header_location]
    assert_equal "somefile.txt", first_cdir_header[:filename]
    assert_equal 8, first_cdir_header[:gp_flags]
    assert_equal 8, first_cdir_header[:storage_mode]
    assert_equal 19, first_cdir_header[:compressed_size]
    assert_equal 17, first_cdir_header[:uncompressed_size]
    assert_equal 2729945713, first_cdir_header[:crc32]

    assert_equal 19, second_cdir_header[:local_file_header_location]
    assert_equal "uncompressed.txt", second_cdir_header[:filename]
    assert_equal 8, second_cdir_header[:gp_flags]
    assert_equal 0, second_cdir_header[:storage_mode]
    assert_equal 22, second_cdir_header[:compressed_size]
    assert_equal 22, second_cdir_header[:uncompressed_size]
    assert_equal 1550572917, second_cdir_header[:crc32]

    assert_operator eocd[:start_of_central_directory_location], :>, 0
    assert_operator eocd[:central_directory_size], :>, 0
    assert_equal 2, eocd[:num_files_in_archive]
  end

  test "allows the yielded writable sinks to be closed twice even when using a block" do
    out = StringIO.new
    fake_w = RecordingWriter.new

    ZipKit::Streamer.open(out, writer: fake_w) do |z|
      z.write_deflated_file("somefile.txt", &:close)
      z.write_stored_file("uncompressed.txt", &:close)
    end

    assert_equal [
      :write_local_file_header,
      :write_data_descriptor,
      :write_local_file_header,
      :write_data_descriptor,
      :write_central_directory_file_header,
      :write_central_directory_file_header,
      :write_end_of_central_directory
    ], fake_w.called_methods
  end

  test "supports deferred writes using the return values from write_deflated_file and write_stored_file" do
    out = StringIO.new
    fake_w = RecordingWriter.new

    ZipKit::Streamer.open(out, writer: fake_w) do |z|
      out = z.write_deflated_file("somefile.txt")
      out << "Experimental data"
      out.close

      out = z.write_stored_file("uncompressed.txt")
      out << "Some uncompressed data"
      out.close
    end

    assert_equal [
      :write_local_file_header,
      :write_data_descriptor,
      :write_local_file_header,
      :write_data_descriptor,
      :write_central_directory_file_header,
      :write_central_directory_file_header,
      :write_end_of_central_directory
    ], fake_w.called_methods
  end

  test "creates an archive with data descriptors that can be opened by Rubyzip, with a small number of very tiny text files" do
    tf = ManagedTempfile.new("zip")
    ZipKit::Streamer.open(tf) do |zip|
      zip.write_stored_file("stored.txt") do |sink|
        sink << File.binread(__dir__ + "/war-and-peace.txt")
      end
      zip.write_deflated_file("deflated.txt") do |sink|
        sink << File.binread(__dir__ + "/war-and-peace.txt")
      end
    end
    tf.flush

    Zip::File.foreach(tf.path) do |entry|
      # Make sure it is tagged as UNIX
      assert_equal 3, entry.fstype

      # The CRC
      assert_equal Zlib.crc32(File.binread(__dir__ + "/war-and-peace.txt")), entry.crc

      # Check the name
      assert_match(/\.txt$/, entry.name)

      # Check the right external attributes (non-executable on UNIX)
      assert_equal 2_175_008_768, entry.external_file_attributes

      # Check the file contents
      readback = entry.get_input_stream.read
      readback.force_encoding(Encoding::BINARY)
      assert_equal File.binread(__dir__ + "/war-and-peace.txt")[0..10], readback[0..10]
    end
  end

  test "can create a valid ZIP archive without any files" do
    tf = ManagedTempfile.new("zip")

    ZipKit::Streamer.open(tf) do |zip|
    end

    tf.flush
    tf.rewind

    yielded = false
    Zip::File.foreach(tf.path) { yielded = true }
    refute yielded
  end

  test "prevents duplicates in the stored files" do
    files = [
      "README", "README", 'file.one\\two.jpg', "file_one.jpg", "file_one (1).jpg",
      'file\\one.jpg', "My.Super.file.txt.zip", "My.Super.file.txt.zip"
    ]
    fake_writer = RecordingWriter.new
    zip_streamer = ZipKit::Streamer.new(StringIO.new, writer: fake_writer, auto_rename_duplicate_filenames: true)
    files.each do |fn|
      zip_streamer.add_stored_entry(filename: fn, size: 1_024, crc32: 0xCC)
    end
    seen_filenames = fake_writer.kwargs_of(:write_local_file_header).map { |kwargs| kwargs[:filename] }
    assert_equal [
      "README", "README (1)", "file.one_two.jpg", "file_one.jpg",
      "file_one (1).jpg", "file_one (2).jpg", "My.Super.file.txt.zip",
      "My.Super.file (1).txt.zip"
    ], seen_filenames
  end

  test "raises when a file would clobber a directory or vice versa (without automatic deduping)" do
    assert_raises(ZipKit::PathSet::Conflict) {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, auto_rename_duplicate_filenames: false)
      zip_streamer.add_empty_directory(dirname: "foo/bar/baz")
      zip_streamer.add_stored_entry(filename: "foo/bar/baz", size: 1_024, crc32: 0xCC)
    }

    assert_raises(ZipKit::PathSet::Conflict) {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, auto_rename_duplicate_filenames: false)
      zip_streamer.add_empty_directory(dirname: "foo/bar/baz")
      zip_streamer.add_deflated_entry(filename: "foo/bar/baz", compressed_size: 1_024, uncompressed_size: 12548, crc32: 0xCC)
    }

    assert_raises(ZipKit::PathSet::Conflict) {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, auto_rename_duplicate_filenames: false)
      zip_streamer.add_stored_entry(filename: "foo/bar/baz", size: 1_024, crc32: 0xCC)
      zip_streamer.add_empty_directory(dirname: "foo/bar/baz")
    }

    assert_raises(ZipKit::PathSet::Conflict) {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, auto_rename_duplicate_filenames: false)
      zip_streamer.add_stored_entry(filename: "foo/bar/baz", size: 1_024, crc32: 0xCC)
      zip_streamer.add_stored_entry(filename: "foo/bar/baz/bad", size: 1_024, crc32: 0xCC)
    }

    assert_raises(ZipKit::PathSet::Conflict) {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, auto_rename_duplicate_filenames: false)
      zip_streamer.add_stored_entry(filename: "a/b", size: 1_024, crc32: 0xCC)
      zip_streamer.add_empty_directory(dirname: "a/b/c")
    }

    assert_raises(ZipKit::PathSet::Conflict) {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, auto_rename_duplicate_filenames: false)
      zip_streamer.add_empty_directory(dirname: "a/b/c")
      zip_streamer.add_stored_entry(filename: "a/b", size: 1_024, crc32: 0xCC)
    }
  end

  def read_entries_with_rubyzip(zip_path)
    per_filename = {}
    Zip::File.open(zip_path) do |zipfile|
      zipfile.each { |entry| per_filename[entry.name] = entry.directory? ? :directory : entry.get_input_stream.read }
    end
    per_filename
  end

  test "allows adding an empty directory and then a file inside it" do
    zip_file = ManagedTempfile.new("z")
    zip_file.binmode

    assert_nothing_raised do
      ZipKit::Streamer.open(zip_file) do |zip|
        zip.add_empty_directory(dirname: "foo")
        zip.write_deflated_file("foo/index.html") { |sink| sink << "Hello" }
      end
    end
    zip_file.flush

    assert_equal({"foo/" => :directory, "foo/index.html" => "Hello"}, read_entries_with_rubyzip(zip_file.path))
  end

  test "allows adding a file and then the empty directory it is in" do
    zip_file = ManagedTempfile.new("z")
    zip_file.binmode

    assert_nothing_raised do
      ZipKit::Streamer.open(zip_file) do |zip|
        zip.write_deflated_file("foo/index.html") { |sink| sink << "Hello" }
        zip.add_empty_directory(dirname: "foo")
      end
    end
    zip_file.flush

    assert_equal({"foo/index.html" => "Hello", "foo/" => :directory}, read_entries_with_rubyzip(zip_file.path))
  end

  test "raises when a file would clobber another file (without automatic deduping)" do
    fake_writer = RecordingWriter.new
    assert_raises(ZipKit::PathSet::Conflict) {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, writer: fake_writer, auto_rename_duplicate_filenames: false)
      zip_streamer.add_stored_entry(filename: "foo/bar/baz", size: 1_024, crc32: 0xCC)
      zip_streamer.add_stored_entry(filename: "foo/bar/baz", size: 14, crc32: 0x0C)
    }

    assert_raises(ZipKit::PathSet::Conflict) {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, writer: fake_writer, auto_rename_duplicate_filenames: false)
      zip_streamer.add_stored_entry(filename: "foo", size: 1_024, crc32: 0xCC)
      zip_streamer.add_stored_entry(filename: "foo", size: 14, crc32: 0x0C)
    }
  end

  test "raises when a file would clobber a directory or vice versa (when automatic filename deduplication is enabled)" do
    fake_writer = RecordingWriter.new
    assert_raises(ZipKit::PathSet::Conflict) {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, writer: fake_writer, auto_rename_duplicate_filenames: true)
      zip_streamer.add_stored_entry(filename: "foo/bar/baz", size: 1_024, crc32: 0xCC)
      zip_streamer.add_stored_entry(filename: "foo/bar/baz/bad", size: 1_024, crc32: 0xCC)
    }

    # Contrary to what one would think, the order in which entries get added in this instance matters.
    # When the "outer" file with a conflicting name gets created first, and the file which is inside
    # that path gets created later, the "shorter" path will be deduplicated (the last element will be
    # changed to "baz (1)" to avoid conflict). This is certainly usable, but is _magic_ behavior -
    # which is one of the reasons why automatically fixing non-unique filenames is a bad idea,
    # and we are going to make it optional - it can lead to very non-intuitive behavior
    assert_nothing_raised {
      zip_streamer = ZipKit::Streamer.new(StringIO.new, writer: fake_writer, auto_rename_duplicate_filenames: true)
      zip_streamer.add_stored_entry(filename: "foo/bar/baz/bad", size: 1_024, crc32: 0xCC)
      # The error raised would be ZipKit::PathSet::Conflict
      zip_streamer.add_stored_entry(filename: "foo/bar/baz", size: 1_024, crc32: 0xCC)
    }
  end

  test "raises when the IO offset is out of sync with the sizes of the entries known to the Streamer" do
    error = assert_raises(ZipKit::Streamer::OffsetOutOfSync) {
      ZipKit::Streamer.open(StringIO.new, auto_rename_duplicate_filenames: false) do |zip_streamer|
        zip_streamer.add_stored_entry(filename: "foo/bar/baz", size: 1_024, crc32: 0xCC)
      end
    }
    assert_match(/Entries add up to \d+ bytes and the IO is at 50 bytes/, error.message)
  end

  test "writes the specified modification time" do
    fake_writer = RecordingWriter.new

    ZipKit::Streamer.open(StringIO.new, writer: fake_writer) do |zip|
      zip.write_stored_file("stored.txt", modification_time: Time.new(2018, 1, 1)) do |sink|
        sink << "stored"
      end
      zip.write_deflated_file("deflated.txt", modification_time: Time.new(2018, 1, 1)) do |sink|
        sink << "deflated"
      end
      zip.add_empty_directory(dirname: "empty", modification_time: Time.new(2018, 1, 1))
    end

    local_headers = fake_writer.kwargs_of(:write_local_file_header)
    assert_equal 3, local_headers.length
    local_headers.each do |kwargs|
      assert_equal Time.new(2018, 1, 1), kwargs[:mtime]
    end
  end

  test "writes the same DOS time into the local and central directory headers, without converting the given Time to UTC" do
    out = StringIO.new
    mtime = Time.new(2018, 1, 1, 23, 30, 0, "+02:00")
    ZipKit::Streamer.open(out) do |zip|
      zip.write_stored_file("stored.txt", modification_time: mtime) { |sink| sink << "stored" }
    end
    assert_equal 2 * 60 * 60, mtime.utc_offset

    from_local_header = ZipKit::FileReader.new.read_local_file_header(io: StringIO.new(out.string))
    from_central_directory = ZipKit::FileReader.read_zip_structure(io: StringIO.new(out.string)).first
    dos_time_23_30 = (30 << 5) + (23 << 11)
    assert_equal dos_time_23_30, from_local_header.dos_time
    assert_equal dos_time_23_30, from_central_directory.dos_time
    assert_equal from_local_header.dos_date, from_central_directory.dos_date
  end

  test "supports automatic mode selection using a heuristic" do
    zip_file = ManagedTempfile.new
    rng = Random.new(42)
    repeating_string = "many many delicious, compressible words"
    n_writes = 24000
    high_entropy_write_size = 999
    ZipKit::Streamer.open(zip_file) do |zip|
      zip.write_file("this will be stored.bin") do |io|
        n_writes.times do
          io << rng.bytes(high_entropy_write_size)
        end
      end

      w = zip.write_file("this will be deflated.bin")
      n_writes.times do
        write_result = w.write(repeating_string)
        assert_equal repeating_string.bytesize, write_result
      end
      w.close

      zip.write_file("empty.bin") do |io|
        # Do nothing
      end

      zip.write_file("tiny.bin") do |io|
        io << "a"
      end
    end

    zip_file.flush
    file_contents = {}
    compression_methods = {}
    Zip::File.open(zip_file.path) do |zipfile|
      # Handle entries one by one
      zipfile.each do |entry|
        file_contents[entry.name] = entry.get_input_stream.read
        compression_methods[entry.name] = entry.compression_method
      end
    end

    assert_equal n_writes * high_entropy_write_size, file_contents["this will be stored.bin"].bytesize
    assert_equal 0, compression_methods["this will be stored.bin"]

    assert_equal n_writes * repeating_string.bytesize, file_contents["this will be deflated.bin"].bytesize
    assert_equal 8, compression_methods["this will be deflated.bin"]

    assert_equal 0, file_contents["empty.bin"].bytesize
    assert_equal 0, compression_methods["empty.bin"]

    assert_equal "a", file_contents["tiny.bin"]
    assert_equal 0, compression_methods["empty.bin"]
  end

  test "rolls back entries where writes have failed" do
    zip_file = ManagedTempfile.new("zipp")
    ZipKit::Streamer.open(zip_file) do |zip|
      begin
        zip.write_deflated_file("deflated.txt", modification_time: Time.new(2018, 1, 1)) do |sink|
          sink << "this is attempt 1"
          raise "Oops"
        end
      rescue => e
        assert_match(/Oops/, e.to_s)
      end

      zip.write_deflated_file("deflated.txt", modification_time: Time.new(2018, 1, 1)) do |sink|
        sink << "this is attempt 2"
      end

      begin
        zip.write_stored_file("stored.txt", modification_time: Time.new(2018, 1, 1)) do |sink|
          sink << "this is attempt 1"
          raise "Oops"
        end
      rescue => e
        assert_match(/Oops/, e.to_s)
      end

      zip.write_stored_file("stored.txt", modification_time: Time.new(2018, 1, 1)) do |sink|
        sink << "this is attempt 2"
      end
    end
    zip_file.flush

    per_filename = {}
    Zip::File.open(zip_file.path) do |zipfile|
      # Handle entries one by one
      zipfile.each do |entry|
        # The entry name gets returned with a binary encoding, we have to force it back.
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    assert_equal 2, per_filename.size
    assert_equal "this is attempt 2", per_filename["deflated.txt"]
    assert_equal "this is attempt 2", per_filename["stored.txt"]
  end

  test "does not count rolled back entries in the end of central directory record" do
    out = +""
    ZipKit::Streamer.open(out) do |zip|
      zip.write_stored_file("first.txt") { |sink| sink << "first" }
      begin
        zip.write_stored_file("failed.txt") do |sink|
          sink << "partial"
          raise "Oops"
        end
      rescue => e
        assert_match(/Oops/, e.to_s)
      end
      zip.write_deflated_file("second.txt") { |sink| sink << "second" }
    end

    entries = ZipKit::FileReader.read_zip_structure(io: StringIO.new(out))
    assert_equal ["first.txt", "second.txt"], entries.map(&:filename)
  end

  test "correctly rolls back if an exception is raised from Writable#close when using write_file" do
    # A Unicode string will not be happy about binary writes
    # and will raise an exception. The exception won't be raised when
    # starting the writes, but in `#close` of the Writable with write_file. When the size of the byte
    # stream is small, the decision whether to call write_stored_file or write_deflated_file is going to
    # be deferred until the Writable gets close() called on it. In that situation a correct rollback
    # must be performed.
    # If this is not handled correctly, the exception we will get raised won't be the original exception
    # (Encoding::CompatibilityError that we need to see - to know what went wrong inside the writing block)
    # but a PathSet::Conflict duplicate zip entry exception. Also, the IO offsets will be out of whack.
    # To cause this, we need something that will raise during `Writable#close` - we will use a Unicode string
    # for that purpose. See https://github.com/julik/zip_kit/issues/15
    uniсode_str_buf = +"Ж"

    zip = ZipKit::Streamer.new(uniсode_str_buf)
    4.times do
      assert_raises(Encoding::CompatibilityError) { # Should not be a PathSet::Conflict
        zip.write_file("deflated.txt") do |sink|
          sink.write("x")
        end
      }
    end

    # We must force the string into binary so that the ZIP can be closed - we
    # want to write out the EOCD since we want to make sure there is no byte offset
    # mismatch (fillers have been correctly produced)
    uniсode_str_buf.force_encoding(Encoding::BINARY)
    assert_nothing_raised { zip.close } # Offset validation should pass
  end

  test "handles rollback when first entry fails before header is written" do
    # This test reproduces the issue described in https://github.com/julik/zip_kit/issues/26
    # When the first entry fails to add (e.g., due to an invalid URL or other error
    # before the local file header is written), rollback! should not fail with a TypeError.
    # This can happen when using write_file with Heuristic, where an exception occurs
    # in the block before the Heuristic decides which compression method to use and
    # calls write_deflated_file/write_stored_file (which would set @offset_before_last_local_file_header).
    zip = ZipKit::Streamer.new(StringIO.new)

    # Simulate a scenario where an exception occurs in the block passed to write_file
    # before the Heuristic calls write_deflated_file or write_stored_file (which would
    # set @offset_before_last_local_file_header). This happens when the exception
    # occurs before close() is called on the Heuristic writable.
    error = assert_raises(RuntimeError) {
      zip.write_file("test.txt") do |sink|
        # Raise an error before any data is written, so the Heuristic hasn't decided
        # which compression method to use yet, and no header has been written
        raise "Invalid URL or other error"
      end
    }
    assert_equal "Invalid URL or other error", error.message

    assert_nothing_raised { zip.rollback! }

    assert_nothing_raised { zip.close }
  end

  test "handles rollback when second entry fails before header is written, preserving first entry" do
    # This test reproduces the bug where rollback! uses stale values from a previous
    # successful entry when a new entry fails before writing a header.
    # When write_file fails before the Heuristic calls write_deflated_file/write_stored_file,
    # rollback! should not affect the previous successful entry.
    zip_file = ManagedTempfile.new("zipp")
    zip = ZipKit::Streamer.new(zip_file)

    # First entry succeeds
    zip.write_file("success.txt") do |sink|
      sink << "successful content"
    end

    # Second entry fails before header is written (exception in Heuristic before decide)
    error = assert_raises(RuntimeError) {
      zip.write_file("fail.txt") do |sink|
        # Raise an error before any data is written, so the Heuristic hasn't decided
        # which compression method to use yet, and no header has been written
        raise "Invalid URL or other error"
      end
    }
    assert_equal "Invalid URL or other error", error.message

    # rollback! should not affect the first entry
    assert_nothing_raised { zip.rollback! }

    # Should be able to close successfully
    assert_nothing_raised { zip.close }

    zip_file.flush

    # Verify the final ZIP file contains only the first entry with correct content
    per_filename = {}
    Zip::File.open(zip_file.path) do |zipfile|
      zipfile.each do |entry|
        per_filename[entry.name] = entry.get_input_stream.read
      end
    end

    assert_equal 1, per_filename.size
    assert_equal "successful content", per_filename["success.txt"]
  end
end
