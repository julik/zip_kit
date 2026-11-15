require "test_helper"

class StreamerWritableTest < TestCase
  # Records the kwargs of every `update_last_entry_and_write_data_descriptor` call
  class FakeStreamer
    attr_reader :data_descriptor_writes

    def initialize
      @data_descriptor_writes = []
    end

    def update_last_entry_and_write_data_descriptor(**kwargs)
      @data_descriptor_writes << kwargs
      0
    end
  end

  class FakeDeflater
    attr_reader :finish_calls

    def initialize(finish_result)
      @finish_result = finish_result
      @finish_calls = 0
    end

    def finish
      @finish_calls += 1
      @finish_result
    end
  end

  describe "#<<" do
    test "writes the given data to the destination and returns self" do
      buf = StringIO.new
      writable = ZipKit::Streamer::Writable.new(Object.new, buf)

      result = writable << "hello!"

      assert_equal "hello!", buf.string
      assert_equal writable, result
    end

    test "raises if the write is attempted after closing" do
      writable = ZipKit::Streamer::Writable.new(FakeStreamer.new, FakeDeflater.new({}))

      writable.close
      error = assert_raises(RuntimeError) { writable << "foo" }
      assert_match(/closed/, error.message)
    end

    test "only passes binary strings to the target" do
      fake_streamer = Object.new
      fake_deflater = Object.new
      def fake_deflater.<<(data)
        raise "data passed must be in binary" unless data.encoding == Encoding::BINARY
      end

      writable = ZipKit::Streamer::Writable.new(fake_streamer, fake_deflater)
      assert_nothing_raised { writable << "é" }
    end
  end

  describe "#close" do
    test "finishes the writer and writes data descriptor on the Streamer" do
      streamer = FakeStreamer.new
      deflater = FakeDeflater.new(crc32: 1, compressed_size: 2, uncompressed_size: 3)

      ZipKit::Streamer::Writable.new(streamer, deflater).close

      assert_equal 1, deflater.finish_calls
      assert_equal [{crc32: 1, compressed_size: 2, uncompressed_size: 3}], streamer.data_descriptor_writes
    end

    test "does not write the data descriptor twice" do
      streamer = FakeStreamer.new
      deflater = FakeDeflater.new({})

      writable = ZipKit::Streamer::Writable.new(streamer, deflater)
      4.times { writable.close }

      assert_equal 1, deflater.finish_calls
      assert_equal 1, streamer.data_descriptor_writes.length
    end
  end

  describe "#write" do
    test "writes the given data to the destination and returns the number of bytes written" do
      buf = StringIO.new
      writable = ZipKit::Streamer::Writable.new(Object.new, buf)

      result = writable.write("hello!")

      assert_equal "hello!", buf.string
      assert_equal 6, result
    end
  end
end
