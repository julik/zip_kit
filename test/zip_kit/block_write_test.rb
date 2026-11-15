require "test_helper"

class BlockWriteTest < TestCase
  test "calls the given block each time data is written" do
    blobs = []
    adapter = ZipKit::BlockWrite.new { |s| blobs << s }

    adapter << "hello"
    adapter << "world"
    adapter << "!"

    assert_equal ["hello", "world", "!"], blobs
  end

  test "supports chained shovel" do
    blobs = []
    adapter = ZipKit::BlockWrite.new { |s| blobs << s }

    adapter << "hello" << "world" << "!"

    assert_equal ["hello", "world", "!"], blobs
  end

  test "supports write()" do
    blobs = []
    adapter = ZipKit::BlockWrite.new { |s| blobs << s }

    assert_equal 5, adapter.write("hello")
    assert_equal 6, adapter.write("worlde")
    assert_equal 1, adapter.write("!")

    assert_equal ["hello", "worlde", "!"], blobs
  end

  test "can write in all possible encodings, even if the strings are frozen" do
    accum_string = +""
    adapter = ZipKit::BlockWrite.new { |s| accum_string << s }

    adapter << "hello"
    adapter << "привет"
    adapter << "привет".freeze
    adapter << "!"
    adapter << Random.new.bytes(1_024)

    assert_equal 1_054, accum_string.bytesize
  end

  test "forces the written strings to binary encoding" do
    blobs = []
    adapter = ZipKit::BlockWrite.new { |s| blobs << s }
    adapter << "hello".encode(Encoding::UTF_8)
    adapter << "world".encode(Encoding::BINARY)
    adapter << "!"
    refute_predicate blobs, :empty?
    blobs.each { |s| assert_equal Encoding::BINARY, s.encoding }
  end

  test "does not change the encoding of source strings" do
    hello = "hello".encode(Encoding::UTF_8)
    accum_string = (+"").force_encoding(Encoding::BINARY)
    adapter = ZipKit::BlockWrite.new { |s| accum_string << s }
    adapter << hello
    assert_equal Encoding::BINARY, accum_string.encoding
    assert_equal Encoding::UTF_8, hello.encoding
  end

  test "omits strings of zero length" do
    blobs = []
    adapter = ZipKit::BlockWrite.new { |s| blobs << s }
    adapter << "hello"
    adapter << ""
    adapter << "!"
    assert_equal ["hello", "!"], blobs
  end

  test "omits nils" do
    blobs = []
    adapter = ZipKit::BlockWrite.new { |s| blobs << s }
    adapter << "hello"
    adapter << nil
    adapter << "!"
    assert_equal ["hello", "!"], blobs
  end

  test "raises a TypeError on specific unsupported methods" do
    adapter = ZipKit::BlockWrite.new { |s| }
    error = assert_raises(RuntimeError) { adapter.seek(123) }
    assert_match(/non-rewindable/, error.message)

    error = assert_raises(RuntimeError) { adapter.to_s }
    assert_match(/non-rewindable/, error.message)

    error = assert_raises(RuntimeError) { adapter.pos = 123 }
    assert_match(/non-rewindable/, error.message)
  end
end
