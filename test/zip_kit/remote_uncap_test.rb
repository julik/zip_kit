require "test_helper"
require "net/http"
require "tmpdir"

class RemoteUncapTest < TestCase
  # The Rack app serves the directory Puma was started in. Parallel test workers
  # each get a directory (and a Puma) of their own, so that they do not clobber each other's ZIP.
  def self.served_dir
    @served_dir ||= Dir.mktmpdir("zip_kit_remote_uncap").tap do |dir|
      Minitest.after_run { FileUtils.remove_entry(dir, true) }
    end
  end

  def setup
    super
    @temp_zip_path = File.join(self.class.served_dir, "temp.zip")
    @server_addr = PumaServer.boot(File.expand_path("remote_uncap_rack_app.ru", __dir__), chdir: self.class.served_dir)
  end

  def teardown
    begin
      File.unlink(@temp_zip_path)
    rescue Errno::ENOENT
    end
    super
  end

  test 'returns an array of remote entries that can be used to fetch the segments \
      from within the ZIP' do
    payload1 = ManagedTempfile.new "payload1"
    payload1 << Random.new.bytes((1024 * 1024 * 5) + 10)
    payload1.flush
    payload1.rewind

    payload2 = ManagedTempfile.new "payload2"
    payload2 << Random.new.bytes(1024 * 1024 * 3)
    payload2.flush
    payload2.rewind

    File.open(@temp_zip_path, "wb") do |f|
      ZipKit::Streamer.open(f) do |zip|
        zip.write_stored_file("first-file.bin") { |w| IO.copy_stream(payload1, w) }
        zip.write_stored_file("second-file.bin") { |w| IO.copy_stream(payload2, w) }
      end
    end
    payload1.rewind
    payload2.rewind

    files = ZipKit::RemoteUncap.files_within_zip_at("http://#{@server_addr}/temp.zip")
    assert_kind_of Array, files
    assert_equal 2, files.length

    first, second = *files

    assert_equal "first-file.bin", first.filename
    assert_equal payload1.size, first.uncompressed_size
    File.open(@temp_zip_path, "rb") do |readback|
      readback.seek(first.compressed_data_offset, IO::SEEK_SET)
      assert_equal payload1.read(12), readback.read(12)
    end

    assert_equal "second-file.bin", second.filename
    assert_equal payload2.size, second.uncompressed_size
    File.open(@temp_zip_path, "rb") do |readback|
      readback.seek(second.compressed_data_offset, IO::SEEK_SET)
      assert_equal payload2.read(12), readback.read(12)
    end
  end

  test "can cope with an empty file within the zip" do
    payload1 = ManagedTempfile.new "payload1"
    payload1.flush
    payload1.rewind

    payload2 = ManagedTempfile.new "payload2"
    payload2 << Random.new.bytes(1024)
    payload2.flush
    payload2.rewind

    payload1_crc = Zlib.crc32(payload1.read).tap { payload1.rewind }

    File.open(@temp_zip_path, "wb") do |f|
      ZipKit::Streamer.open(f) do |zip|
        zip.add_stored_entry(filename: "first-file-zero-size.bin",
          size: payload1.size,
          crc32: payload1_crc)
        zip.write_stored_file("second-file.bin") { |w| IO.copy_stream(payload2, w) }
      end
    end
    payload1.rewind
    payload2.rewind

    first, second = ZipKit::RemoteUncap.files_within_zip_at("http://#{@server_addr}/temp.zip")

    assert_equal "first-file-zero-size.bin", first.filename
    assert_predicate first.compressed_size, :zero?

    assert_equal "second-file.bin", second.filename
    assert_equal payload2.size, second.uncompressed_size
    File.open(@temp_zip_path, "rb") do |source_zip|
      source_zip.seek(second.compressed_data_offset, IO::SEEK_SET)
      assert_equal payload2.read(12), source_zip.read(12)
    end
  end
end
