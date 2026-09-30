require_relative "../spec_helper"

describe ZipKit::WriteBuffer do
  # The WriteBuffer reuses strings, so examining its output is easier via Arrays
  # if duplication gets applied on every write
  class Duplicator < Struct.new(:accumulator)
    def <<(data)
      accumulator << data.dup
      self
    end
  end

  shared_examples "a WriteBuffer" do
    it "returns self from <<" do
      sink = []
      adapter = described_class.new(sink, 1024)
      expect(adapter << "a").to eq(adapter)
    end

    it "performs appends to the buffer in binary encoding only" do
      # The WriteBuffer reuses strings, so for a good reproduction
      # we need the sink to be something realistic
      sink = "å".b
      buffer = described_class.new(sink, 1)

      expect {
        2.times { buffer << "é".encode(Encoding::UTF_8) }
      }.not_to raise_error
    end

    it "appends the written strings in one go for the set buffer size" do
      sink = double("Writable")

      expect(sink).to receive(:<<).with("quick brown fox")
      expect(sink).to receive(:<<).with(" jumps over the")

      adapter = described_class.new(sink, "quick brown fox".bytesize)
      "quick brown fox jumps over the".each_char do |char|
        adapter << char
      end

      adapter.flush
    end

    it "bypasses larger writes, even if the amount of data accumulated is smaller than bufsize" do
      accumulator = []
      subject = described_class.new(Duplicator.new(accumulator), 12)
      subject << "one"
      subject << "a much larger larger larger string which  is larger than the buffer size"
      subject << "some more data"
      subject.flush

      expect(accumulator).to eq([
        "one",
        "a much larger larger larger string which  is larger than the buffer size",
        "some more data"
      ])
      expect(accumulator.map(&:encoding).uniq).to eq([Encoding::BINARY])
    end

    it "flushes before the buffer would overflow, so that chunks never exceed the buffer size" do
      accumulator = []
      subject = described_class.new(Duplicator.new(accumulator), 8)
      subject << "abcde" << "fgh" # exactly 8 bytes, not flushed yet
      subject << "ij" # would overflow, so "abcdefgh" gets flushed first
      subject << "klmnop" # fills the buffer up to 8 bytes again
      subject << "q" # would overflow, so "ijklmnop" gets flushed first
      subject.flush

      expect(accumulator).to eq(["abcdefgh", "ijklmnop", "q"])
    end

    it "passes writes larger than the buffer size through intact, also when buffering" do
      accumulator = []
      subject = described_class.new(Duplicator.new(accumulator), 64 * 1024)
      large = Random.new(42).bytes(3 * 64 * 1024 + 17)
      large_utf8 = "Широкая строка " * 10_000
      subject << "x"
      subject << large
      subject << "y"
      subject << large_utf8
      subject.flush

      expect(accumulator).to eq(["x", large, "y", large_utf8.b])
      expect(accumulator.map(&:encoding).uniq).to eq([Encoding::BINARY])
      expect(large_utf8.encoding).to eq(Encoding::UTF_8)
    end

    it "passes writes of exactly the buffer size through without buffering them" do
      received = []
      sink = Object.new
      sink.define_singleton_method(:<<) do |str|
        received << [str.object_id, str.dup]
        self
      end
      subject = described_class.new(sink, 4)
      internal_buffer_id = subject.instance_variable_get(:@buf).object_id

      subject << "abcd" << "efgh" << "ijkl"
      subject.flush

      expect(received.map(&:last)).to eq(["abcd", "efgh", "ijkl"])
      expect(received.map(&:first)).not_to include(internal_buffer_id)
    end

    it "coalesces lots of tiny UTF-8 writes into buffer-sized chunks" do
      accumulator = []
      subject = described_class.new(Duplicator.new(accumulator), 1024)
      fragments = []
      10_000.times do |i|
        fragments << "<c r=\"" << "A#{i}" << "\">" << i.to_s << "</c>"
      end
      fragments.each { |fragment| subject << fragment }
      subject.flush

      expect(accumulator.join).to eq(fragments.join.b)
      max_fragment_size = fragments.map(&:bytesize).max
      expect(accumulator[0...-1].map(&:bytesize)).to all(be_between(1024 - max_fragment_size, 1024))
      expect(accumulator.map(&:encoding).uniq).to eq([Encoding::BINARY])
    end

    it "does not change the encoding of, or modify, the strings written into it" do
      accumulator = []
      subject = described_class.new(Duplicator.new(accumulator), 4)
      utf8 = "Привет, мир"
      binary = [0xFF, 0x00, 0xC3].pack("C*")
      frozen = "frozen literal"
      subject << utf8 << binary << frozen
      subject.flush

      expect(utf8.encoding).to eq(Encoding::UTF_8)
      expect(utf8).to eq("Привет, мир")
      expect(binary.encoding).to eq(Encoding::BINARY)
      expect(accumulator.join).to eq(utf8.b + binary + frozen.b)
    end

    it "accepts non-ASCII UTF-8 strings mixed with binary strings in any order" do
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
          subject = described_class.new(Duplicator.new(accumulator), buffer_size)
          expect {
            strings.each { |s| subject << s }
            subject.flush
          }.not_to raise_error

          expect(accumulator.join).to eq(strings.map(&:b).join)
          expect(accumulator.map(&:encoding).uniq).to eq([Encoding::BINARY])
        end
      end
    end

    it "hands the writable a binary String even when only UTF-8 strings were written" do
      received_encodings = []
      sink = ->(str) { received_encodings << str.encoding }
      def sink.<<(str)
        call(str)
        self
      end

      subject = described_class.new(sink, 8)
      subject << "Grüße aus Köln"
      subject << "日本語"
      subject.flush

      expect(received_encodings).not_to be_empty
      expect(received_encodings.uniq).to eq([Encoding::BINARY])
    end

    it "reuses the same String object throughout writes to conserve allocations" do
      accumulator = []
      subject = described_class.new(accumulator, 12)
      subject << "a" << "b" << "c"
      subject.flush
      subject << "d"
      subject.flush

      # The accumulator contains 2 references to the same internal String in the WriteBuffer,
      # and it gets cleared after every flush of the buffer
      expect(accumulator).to eq(["", ""])
      expect(accumulator[0]).to equal(accumulator[1])
    end

    it "clears the buffer after the writable has consumed it, and reuses it for subsequent writes" do
      consumed = []
      received_ids = []
      sink = Object.new
      sink.define_singleton_method(:<<) do |str|
        received_ids << str.object_id
        consumed << str.dup
        self
      end

      subject = described_class.new(sink, 4)
      subject << "ab" << "cd" # flushes "abcd"
      subject << "ef" << "gh" << "i" # flushes "efgh", buffers "i"
      subject << "jkl" # flushes "ijkl"
      subject.flush # nothing left to flush
      subject << "m"
      subject.flush # flushes "m"

      expect(consumed).to eq(["abcd", "efgh", "ijkl", "m"])
      expect(received_ids.uniq.length).to eq(1)
    end

    it "supports flush! in addition to flush" do
      sink = double("Writable")

      expect(sink).to receive(:<<).with("ab")

      adapter = described_class.new(sink, 64)
      adapter << "a" << "b"
      adapter.flush!
    end

    it "does not buffer with buffer size set to 0" do
      sink = double("Writable")

      expect(sink).to receive(:<<).with("a")
      expect(sink).to receive(:<<).with("b")

      adapter = described_class.new(sink, 0)
      adapter << "a" << "b"
    end

    it "flushes the buffer when asked" do
      sink = double("Writable")

      expect(sink).to receive(:<<).with("quick brown fox ")

      adapter = described_class.new(sink, 64 * 1024)

      "quick brown fox ".each_char do |char|
        adapter << char
      end
      adapter.flush
    end
  end

  context "with the String#append_as_bytes support of the running Ruby" do
    it_behaves_like "a WriteBuffer"
  end

  context "without String#append_as_bytes (as on Ruby before 3.4)" do
    before do
      allow(described_class).to receive(:new).and_wrap_original do |original_new, *args|
        original_new.call(*args).tap { |buffer| buffer.instance_variable_set(:@append_as_bytes, false) }
      end
    end

    it_behaves_like "a WriteBuffer"
  end
end
