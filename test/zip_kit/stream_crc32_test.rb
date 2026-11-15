require "test_helper"

class StreamCRC32Test < TestCase
  test "computes the CRC32 of a large binary file" do
    raw = StringIO.new(Random.new.bytes(45 * 1024 * 1024))
    # Rubocop:  warning: Useless assignment to variable
    crc = Zlib.crc32(raw.string)
    via_from_io = ZipKit::StreamCRC32.from_io(raw)
    assert_equal crc, via_from_io
  end

  test "when computing the CRC32 from an IO only allocates one String" do
    raw = StringIO.new(Random.new.bytes(45 * 1024 * 1024))
    # The number of objects allocated depends on the MRI version, but in
    # all cases there is only one String allocated. We work in blocks
    # of 512KB so if we allocate a String for each read() - which is
    # what this spec tries to prevent - we would certainly go over
    # 90 allocations.
    #
    # StreamCRC32 gets autoloaded, and if this test is the first one to touch it the
    # allocations of the autoload would get counted too.
    crc_class = ZipKit::StreamCRC32
    assert_allocates_under(10) { crc_class.from_io(raw) }
  end

  test "allows in-place updates" do
    raw = StringIO.new(Random.new.bytes(45 * 1024 * 1024))
    crc = Zlib.crc32(raw.string)

    stream_crc = ZipKit::StreamCRC32.new
    stream_crc << raw.read(1024 * 64) until raw.eof?
    assert_equal crc, stream_crc.to_i
  end

  test "supports chained shovel" do
    str = "abcdef"
    crc = Zlib.crc32(str)

    stream_crc = ZipKit::StreamCRC32.new
    stream_crc << "a" << "b" << "c" << "d" << "e" << "f"

    assert_equal crc, stream_crc.to_i
  end

  test "allows in-place update with a known value" do
    stream_crc = ZipKit::StreamCRC32.new
    stream_crc << "This is some data"
    stream_crc.append(45_678, 12_910)
    assert_equal 1_555_667_875, stream_crc.to_i
  end
end
