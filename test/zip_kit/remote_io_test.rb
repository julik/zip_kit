require "test_helper"

class RemoteIOTest < TestCase
  def remote_io
    @remote_io ||= ZipKit::RemoteIO.new("http://host.example/some.bin")
  end

  # Replaces a method on the RemoteIO under test and returns the array
  # that collects the arguments of every call to it
  def stub_recording_calls(method_name, &impl)
    calls = []
    remote_io.define_singleton_method(method_name) do |*args|
      calls << args
      impl.call(*args)
    end
    calls
  end

  context "when it internally addresses a remote resource" do
    test 'requests the size of the resource once via #request_object_size and \
        does neet to read if resource is empty' do
      size_requests = stub_recording_calls(:request_object_size) { 0 }
      assert_nil remote_io.read
      assert_equal 1, size_requests.length
    end

    test 'performs remote reads when repeatedly requesting the same chunk, via \
        #request_range' do
      size_requests = stub_recording_calls(:request_object_size) { 120 }
      stub_recording_calls(:request_range) do |range|
        assert_equal 5..14, range
        Random.new.bytes(10)
      end
      20.times do
        remote_io.seek(5, IO::SEEK_SET)
        remote_io.read(10)
      end
      assert_equal 1, size_requests.length
    end
  end

  describe "#seek" do
    context "with an unsupported mode" do
      test "raises an error" do
        error = assert_raises(RuntimeError) { remote_io.seek(123, :UNSUPPORTED) }
        assert_match(/unsupported/i, error.message)
      end
    end

    context "with SEEK_SET mode" do
      test "returns the offset of 10 when asked to seek to 10" do
        size_requests = stub_recording_calls(:request_object_size) { 100 }
        mode = IO::SEEK_SET
        assert_equal 0, remote_io.seek(10, mode)
        assert_equal 1, size_requests.length
      end
    end
  end

  describe "#read" do
    def setup
      super
      @buf = ManagedTempfile.new("simulated-http")
      @buf.binmode
      5.times { @buf << Random.new.bytes(1024 * 1024 * 3) }
      @buf.rewind

      stub_recording_calls(:request_object_size) { @buf.size }
      @range_requests = stub_recording_calls(:request_range) { |range|
        @buf.read[range].tap { @buf.rewind }
      }
    end

    def teardown
      if @buf
        @buf.close
        @buf.unlink
      end
      super
    end

    context "without arguments" do
      test "reads the entire buffer and alters the position pointer" do
        assert_equal 0, remote_io.tell
        read = remote_io.read
        assert_equal @buf.size, read.bytesize
        assert_equal @buf.size, remote_io.tell
      end
    end

    context "with length" do
      test 'supports an unlimited number of reads of size 0 and does not perform \
          remote fetches for them' do
        20.times do
          data = remote_io.read(0)
          assert_equal "", data
        end
        assert_empty @range_requests
      end

      test "returns exact amount of bytes at the start of the buffer" do
        bytes_read = remote_io.read(10)
        assert_equal 10, remote_io.tell
        @buf.seek(0)
        assert_equal @buf.read(10), bytes_read
      end

      test "returns exact amount of bytes from the middle of the buffer" do
        remote_io.seek(456, IO::SEEK_SET)

        bytes_read = remote_io.read(10)
        assert_equal 456 + 10, remote_io.tell

        @buf.seek(456)
        assert_equal @buf.read(10), bytes_read
      end

      test "returns the last N bytes it can read" do
        at_end = @buf.size - 4
        remote_io.seek(at_end, IO::SEEK_SET)

        assert_equal 15_728_636, remote_io.tell
        bytes_read = remote_io.read(10)
        assert_equal @buf.size, remote_io.tell # Should have moved the pos pointer to the end

        assert_equal 4, bytes_read.bytesize

        assert_equal @buf.size, remote_io.tell
      end
    end
  end
end
