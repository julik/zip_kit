# frozen_string_literal: true

# Gets yielded from the writing methods of the Streamer
# and accepts the data being written into the ZIP for deflate
# or stored modes. Can be used as a destination for `IO.copy_stream`
#
#    IO.copy_stream(File.open('source.bin', 'rb), writable)
class ZipKit::Streamer::Writable
  include ZipKit::WriteShovel

  # The amount of bytes we will buffer before computing the intermediate
  # CRC32 checksums. Benchmarks show that the optimum is 64KB (see
  # `bench/buffered_crc32_bench.rb), if that is exceeded Zlib is going
  # to perform internal CRC combine calls which will make the speed go down again.
  CRC32_BUFFER_SIZE = 64 * 1024

  # Initializes a new Writable with the object it delegates the writes to.
  # Normally you would not need to use this method directly
  def initialize(io, &at_close)
    @crc = ZipKit::StreamCRC32.new
    @crc_buf = ZipKit::WriteBuffer.new(@crc, CRC32_BUFFER_SIZE)
    @io = io
    @bytes_in = 0
    @at_close = at_close
  end

  # Writes the given data to the output stream
  #
  # @param d[String] the binary string to write (part of the uncompressed file)
  # @return [self]
  def <<(bytes)
    @crc_buf << bytes
    @io << bytes
    @bytes_in += bytes.bytesize
    self
  end

  # Flushes the writer and recovers the CRC32/size values. It then calls
  # `update_last_entry_and_write_data_descriptor` on the given Streamer.
  def close
    @crc_buf.flush
    @io.close
    @at_close.call(bytes_received: @bytes_in, crc32: @crc.to_i)
  end
end
