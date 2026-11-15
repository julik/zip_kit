require "test_helper"

class WriteBufferTest < TestCase
  # The WriteBuffer reuses strings, so examining its output is easier via Arrays
  # if duplication gets applied on every write
  class Duplicator < Struct.new(:accumulator)
    def <<(data)
      accumulator << data.dup
      self
    end
  end

  a_write_buffer = proc do
    test "returns self from <<" do
      sink = []
      adapter = ZipKit::WriteBuffer.new(sink, 1024)
      assert_equal adapter, adapter << "a"
    end

    test "performs appends to the buffer in binary encoding only" do
      # The WriteBuffer reuses strings, so for a good reproduction
      # we need the sink to be something realistic
      sink = "å".b
      buffer = ZipKit::WriteBuffer.new(sink, 1)

      assert_nothing_raised do
        2.times { buffer << "é".encode(Encoding::UTF_8) }
      end
      assert_equal "åéé".b, sink
    end

    test "appends the written strings in one go for the set buffer size" do
      received = []
      adapter = ZipKit::WriteBuffer.new(Duplicator.new(received), "quick brown fox".bytesize)
      "quick brown fox jumps over the".each_char do |char|
        adapter << char
      end

      adapter.flush

      assert_equal ["quick brown fox", " jumps over the"], received
    end

    test "bypasses larger writes, even if the amount of data accumulated is smaller than bufsize" do
      accumulator = []
      buffer = ZipKit::WriteBuffer.new(Duplicator.new(accumulator), 12)
      buffer << "one"
      buffer << "a much larger larger larger string which  is larger than the buffer size"
      buffer << "some more data"
      buffer.flush

      assert_equal [
        "one",
        "a much larger larger larger string which  is larger than the buffer size",
        "some more data"
      ], accumulator
      assert_equal [Encoding::BINARY], accumulator.map(&:encoding).uniq
    end

    test "flushes before the buffer would overflow, so that chunks never exceed the buffer size" do
      accumulator = []
      buffer = ZipKit::WriteBuffer.new(Duplicator.new(accumulator), 8)
      buffer << "abcde" << "fgh" # exactly 8 bytes, not flushed yet
      buffer << "ij" # would overflow, so "abcdefgh" gets flushed first
      buffer << "klmnop" # fills the buffer up to 8 bytes again
      buffer << "q" # would overflow, so "ijklmnop" gets flushed first
      buffer.flush

      assert_equal ["abcdefgh", "ijklmnop", "q"], accumulator
    end

    test "passes writes larger than the buffer size through intact, also when buffering" do
      accumulator = []
      buffer = ZipKit::WriteBuffer.new(Duplicator.new(accumulator), 64 * 1024)
      large = Random.new(42).bytes(3 * 64 * 1024 + 17)
      large_utf8 = "Широкая строка " * 10_000
      buffer << "x"
      buffer << large
      buffer << "y"
      buffer << large_utf8
      buffer.flush

      assert_equal ["x", large, "y", large_utf8.b], accumulator
      assert_equal [Encoding::BINARY], accumulator.map(&:encoding).uniq
      assert_equal Encoding::UTF_8, large_utf8.encoding
    end

    test "passes writes of exactly the buffer size through without buffering them" do
      received = []
      sink = Object.new
      sink.define_singleton_method(:<<) do |str|
        received << [str.object_id, str.dup]
        self
      end
      buffer = ZipKit::WriteBuffer.new(sink, 4)
      internal_buffer_id = buffer.instance_variable_get(:@buf).object_id

      buffer << "abcd" << "efgh" << "ijkl"
      buffer.flush

      assert_equal ["abcd", "efgh", "ijkl"], received.map(&:last)
      refute_includes received.map(&:first), internal_buffer_id
    end

    test "coalesces lots of tiny UTF-8 writes into buffer-sized chunks" do
      accumulator = []
      buffer = ZipKit::WriteBuffer.new(Duplicator.new(accumulator), 1024)
      fragments = []
      10_000.times do |i|
        fragments << "<c r=\"" << "A#{i}" << "\">" << i.to_s << "</c>"
      end
      fragments.each { |fragment| buffer << fragment }
      buffer.flush

      assert_equal fragments.join.b, accumulator.join
      max_fragment_size = fragments.map(&:bytesize).max
      assert accumulator[0...-1].map(&:bytesize).all? { |size| size.between?(1024 - max_fragment_size, 1024) }
      assert_equal [Encoding::BINARY], accumulator.map(&:encoding).uniq
    end

    test "does not change the encoding of, or modify, the strings written into it" do
      accumulator = []
      buffer = ZipKit::WriteBuffer.new(Duplicator.new(accumulator), 4)
      utf8 = "Привет, мир"
      binary = [0xFF, 0x00, 0xC3].pack("C*")
      frozen = "frozen literal"
      buffer << utf8 << binary << frozen
      buffer.flush

      assert_equal Encoding::UTF_8, utf8.encoding
      assert_equal "Привет, мир", utf8
      assert_equal Encoding::BINARY, binary.encoding
      assert_equal utf8.b + binary + frozen.b, accumulator.join
    end

    test "accepts non-ASCII UTF-8 strings mixed with binary strings in any order" do
      utf8 = "Привет, мир ✓"
      binary = [0xFF, 0xFE, 0x00, 0xC3, 0x28].pack("C*") # Not valid UTF-8
      ascii = "plain"
      utf16 = "wide".encode(Encoding::UTF_16LE)
      sequences = [
        [utf8, binary],
        [binary, utf8],
        [ascii, utf8, binary, utf8, ascii],
        [binary, ascii, utf8, utf8, binary],
        [utf8, utf16, binary, utf8],
        [utf16, utf8]
      ]
      sequences.each do |strings|
        [1, 3, 1024].each do |buffer_size|
          accumulator = []
          buffer = ZipKit::WriteBuffer.new(Duplicator.new(accumulator), buffer_size)
          assert_nothing_raised do
            strings.each { |s| buffer << s }
            buffer.flush
          end

          assert_equal strings.map(&:b).join, accumulator.join
          assert_equal [Encoding::BINARY], accumulator.map(&:encoding).uniq
        end
      end
    end

    test "hands the writable a binary String even when only UTF-8 strings were written" do
      received_encodings = []
      sink = ->(str) { received_encodings << str.encoding }
      def sink.<<(str)
        call(str)
        self
      end

      buffer = ZipKit::WriteBuffer.new(sink, 8)
      buffer << "Grüße aus Köln"
      buffer << "日本語"
      buffer.flush

      refute_predicate received_encodings, :empty?
      assert_equal [Encoding::BINARY], received_encodings.uniq
    end

    test "reuses the same String object throughout writes to conserve allocations" do
      accumulator = []
      buffer = ZipKit::WriteBuffer.new(accumulator, 12)
      buffer << "a" << "b" << "c"
      buffer.flush
      buffer << "d"
      buffer.flush

      # The accumulator contains 2 references to the same internal String in the WriteBuffer,
      # and it gets cleared after every flush of the buffer
      assert_equal ["", ""], accumulator
      assert_same accumulator[0], accumulator[1]
    end

    test "clears the buffer after the writable has consumed it, and reuses it for subsequent writes" do
      consumed = []
      received_ids = []
      sink = Object.new
      sink.define_singleton_method(:<<) do |str|
        received_ids << str.object_id
        consumed << str.dup
        self
      end

      buffer = ZipKit::WriteBuffer.new(sink, 4)
      buffer << "ab" << "cd" # flushes "abcd"
      buffer << "ef" << "gh" << "i" # flushes "efgh", buffers "i"
      buffer << "jkl" # flushes "ijkl"
      buffer.flush # nothing left to flush
      buffer << "m"
      buffer.flush # flushes "m"

      assert_equal ["abcd", "efgh", "ijkl", "m"], consumed
      assert_equal 1, received_ids.uniq.length
    end

    test "supports flush! in addition to flush" do
      received = []
      adapter = ZipKit::WriteBuffer.new(Duplicator.new(received), 64)
      adapter << "a" << "b"
      adapter.flush!

      assert_equal ["ab"], received
    end

    test "does not buffer with buffer size set to 0" do
      received = []
      adapter = ZipKit::WriteBuffer.new(Duplicator.new(received), 0)
      adapter << "a" << "b"

      assert_equal ["a", "b"], received
    end

    test "flushes the buffer when asked" do
      received = []
      adapter = ZipKit::WriteBuffer.new(Duplicator.new(received), 64 * 1024)

      "quick brown fox ".each_char do |char|
        adapter << char
      end
      adapter.flush

      assert_equal ["quick brown fox "], received
    end
  end

  context "with the String#append_as_bytes support of the running Ruby" do
    context "behaves like a WriteBuffer", &a_write_buffer
  end

  context "without String#append_as_bytes (as on Ruby before 3.4)" do
    def setup
      super
      @append_as_bytes_was = ZipKit::WriteBuffer::APPEND_AS_BYTES
      swap_append_as_bytes(false)
    end

    def teardown
      swap_append_as_bytes(@append_as_bytes_was)
      super
    end

    def swap_append_as_bytes(value)
      ZipKit::WriteBuffer.send(:remove_const, :APPEND_AS_BYTES)
      ZipKit::WriteBuffer.const_set(:APPEND_AS_BYTES, value)
    end

    context "behaves like a WriteBuffer", &a_write_buffer
  end
end
