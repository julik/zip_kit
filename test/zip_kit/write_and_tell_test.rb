require "test_helper"

class WriteAndTellTest < TestCase
  test "maintains the count of bytes written" do
    adapter = ZipKit::WriteAndTell.new(+"")
    assert_predicate adapter.tell, :zero?

    adapter << "hello"
    adapter << ""
    adapter << "!"
    assert_equal 6, adapter.tell
  end

  test "is able to write frozen String objects in different encodings, converting them to binary" do
    strs = [
      [12, 123, 0, 3].pack("C*"),
      "текста кусок",
      "текста замороженный кусок".freeze,
      [12, 123, 0, 3].pack("C*")
    ]

    buf = (+"превед").force_encoding(Encoding::BINARY)
    writer = ZipKit::WriteAndTell.new(buf)
    strs.each { |s| writer << s }
    assert_equal 79, writer.tell
    assert_equal 91, buf.bytesize # It already contained some bytes
  end

  test "does not change the encoding of the source string" do
    str = (+"текста кусок").force_encoding(Encoding::UTF_8)
    buf = (+"превед").force_encoding(Encoding::BINARY)
    writer = ZipKit::WriteAndTell.new(buf)
    writer << str
    assert_equal 35, buf.bytesize
    assert_equal Encoding::BINARY, buf.encoding
    assert_equal Encoding::UTF_8, str.encoding
  end

  test "is able to write into a null writer or a blackhole maintaining offsets" do
    writer = ZipKit::WriteAndTell.new(ZipKit::NullWriter)
    writer << "Hello"
    writer << "Goodbye"
    writer << "What a day!"
    writer.advance_position_by(10)
    assert_equal 33, writer.tell
  end

  test "is able to write into an object which only supports write()" do
    stream_with_just_write = Object.new
    def stream_with_just_write.write(bytes)
      # noop
    end

    writer = ZipKit::WriteAndTell.new(stream_with_just_write)
    writer << "Hello"
    writer << "Goodbye"
    writer << "What a day!"
    writer.advance_position_by(10)
    assert_equal 33, writer.tell
  end

  test "advances the internal pointer using advance_position_by" do
    str = +""

    adapter = ZipKit::WriteAndTell.new(str)
    assert_predicate adapter.tell, :zero?

    adapter << "hello"
    adapter << ""
    adapter << "!"
    assert_equal 6, adapter.tell
    adapter.advance_position_by(128_981)
    assert_equal 6 + 128_981, adapter.tell
    assert_equal "hello!", str
  end
end
