require "test_helper"

class StreamerDeflatedWriterTest < TestCase
  test "deflates the data and computes the CRC32 checksum for it" do
    out = StringIO.new

    writer = ZipKit::Streamer::DeflatedWriter.new(out)
    writer << ("a" * 256)
    writer << ("b" * 256)
    writer << ("b" * 256)

    finish_result = writer.finish

    zlib_inflater = ::Zlib::Inflate.new(-Zlib::MAX_WBITS)
    inflated = zlib_inflater.inflate(out.string)
    assert_equal ("a" * 256) + ("b" * 256) + ("b" * 256), inflated

    assert_equal({crc32: 234880044, compressed_size: out.size, uncompressed_size: 768}, finish_result)
  end
end
