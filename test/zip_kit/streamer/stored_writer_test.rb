require "test_helper"

class StreamerStoredWriterTest < TestCase
  test "deflates the data and computes the CRC32 checksum for it" do
    out = StringIO.new

    writer = ZipKit::Streamer::StoredWriter.new(out)
    writer << ("a" * 256)
    writer << ("b" * 256)
    writer << ("b" * 256)

    finish_result = writer.finish

    assert_equal ("a" * 256) + ("b" * 256) + ("b" * 256), out.string

    assert_equal({crc32: 234880044, compressed_size: 768, uncompressed_size: 768}, finish_result)
  end
end
