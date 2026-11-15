require "test_helper"

class BlockDeflateTest < TestCase
  def tag_deflated(deflated_string, raw_string)
    [120, 156].pack("C*") + deflated_string + [3, 0].pack("C*") + [Zlib.adler32(raw_string)].pack("N")
  end

  # Records the calls to a class method of BlockDeflate made within the block, passing them
  # through to the actual method. Returns [positional_args, keyword_args] per call.
  def recording_calls_to(method_name, &blk)
    original = ZipKit::BlockDeflate.method(method_name)
    calls = []
    passthrough = ->(*args, **kwargs) {
      calls << [args, kwargs]
      original.call(*args, **kwargs)
    }
    ZipKit::BlockDeflate.stub(method_name, passthrough, &blk)
    calls
  end

  describe ".deflate_chunk" do
    test 'compresses a blob that can be inflated later, when the header, \
        footer and adler32 are added' do
      blob = "compressible" * (1024 * 4)
      compressed = ZipKit::BlockDeflate.deflate_chunk(blob)
      assert_operator compressed.bytesize, :<, blob.bytesize
      complete_deflated_segment = tag_deflated(compressed, blob)
      assert_equal blob, Zlib::Inflate.inflate(complete_deflated_segment)
    end

    test "removes the header" do
      blob = "compressible" * (1024 * 4)
      compressed = ZipKit::BlockDeflate.deflate_chunk(blob)
      refute_equal [120, 156].pack("C*"), compressed[0..1]
    end

    test "removes the adler32" do
      blob = "compressible" * (1024 * 4)
      compressed = ZipKit::BlockDeflate.deflate_chunk(blob)
      adler = [Zlib.adler32(blob)].pack("N")
      refute compressed.end_with?(adler)
    end

    test "removes the end marker" do
      blob = "compressible" * (1024 * 4)
      compressed = ZipKit::BlockDeflate.deflate_chunk(blob)
      refute_equal [3, 0].pack("C*"), compressed[-7..-5]
    end

    test "honors the compression level" do
      deflater = Zlib::Deflate.new
      new_calls = []
      blob = "compressible" * (1024 * 4)
      Zlib::Deflate.stub(:new, ->(*args) {
        new_calls << args
        deflater
      }) do
        ZipKit::BlockDeflate.deflate_chunk(blob, level: 2)
      end
      assert_equal [[2]], new_calls
    end
  end

  describe "deflate_in_blocks_and_terminate" do
    test "uses deflate_in_blocks" do
      data = "compressible" * (1024 * 1024 * 10)
      input = StringIO.new(data)
      output = StringIO.new
      block_size = 1024 * 64
      calls = recording_calls_to(:deflate_in_blocks) do
        ZipKit::BlockDeflate.deflate_in_blocks_and_terminate(input, output, block_size: block_size)
      end
      assert_equal [[[input, output], {level: -1, block_size: block_size}]], calls
    end

    test "passes a custom compression level" do
      data = "compressible" * (1024 * 1024 * 10)
      input = StringIO.new(data)
      output = StringIO.new
      calls = recording_calls_to(:deflate_in_blocks) do
        ZipKit::BlockDeflate.deflate_in_blocks_and_terminate(input, output, level: Zlib::BEST_COMPRESSION)
      end
      assert_equal [[[input, output], {level: 9, block_size: 5_242_880}]], calls
    end

    test "writes the end marker" do
      data = "compressible" * (1024 * 1024 * 10)
      input = StringIO.new(data)
      output = StringIO.new
      ZipKit::BlockDeflate.deflate_in_blocks_and_terminate(input, output)
      assert_equal [3, 0].pack("C*"), output.string[-2..]
    end
  end

  describe ".write_terminator" do
    test "writes the terminator and returns 2 for number of bytes written" do
      buf = []
      assert_equal 2, ZipKit::BlockDeflate.write_terminator(buf)
      assert_equal [[3, 0].pack("C*")], buf
    end
  end

  describe ".deflate_in_blocks" do
    test "honors the block size" do
      data = "compressible" * (1024 * 1024 * 10)
      input = StringIO.new(data)
      output = StringIO.new
      block_size = 1024 * 64

      num_chunks = (data.bytesize / block_size.to_f).ceil
      read_calls = []
      input.define_singleton_method(:read) do |*args|
        read_calls << args
        super(*args)
      end
      num_writes = 0
      output.define_singleton_method(:<<) do |str|
        num_writes += 1
        super(str)
      end

      deflate_chunk_calls = recording_calls_to(:deflate_chunk) do
        ZipKit::BlockDeflate.deflate_in_blocks(input, output, block_size: block_size)
      end

      assert_equal num_chunks, deflate_chunk_calls.length
      assert_equal [[block_size]] * (num_chunks + 1), read_calls
      assert_equal num_chunks, num_writes
    end

    test "does not write the end marker" do
      input_string = "compressible" * (1024 * 1024 * 10)
      output_string = +""

      ZipKit::BlockDeflate.deflate_in_blocks(StringIO.new(input_string), StringIO.new(output_string))
      refute_predicate output_string, :empty?
      refute output_string.end_with?([3, 0].pack("C*"))
    end

    test "returns the number of bytes written" do
      input_string = "compressible" * (1024 * 1024 * 10)
      output_string = +""

      num_bytes = ZipKit::BlockDeflate.deflate_in_blocks(StringIO.new(input_string),
        StringIO.new(output_string))
      assert_equal 245_016, num_bytes
    end
  end
end
