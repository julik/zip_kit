# frozen_string_literal: true

# Sends writes to the given `io` compressed using a `Zlib::Deflate`. Also
# registers data passing through it in a CRC32 checksum calculator. Is made to be completely
# interchangeable with the StoredWriter in terms of interface.
class ZipKit::Streamer::DeflatedWriter
  def initialize(io)
    @io = io
    @deflater = ::Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -::Zlib::MAX_WBITS)
  end

  # Writes the given data into the deflater, and flushes the deflater
  # after having written more than FLUSH_EVERY_N_BYTES bytes of data
  #
  # @param data[String] data to be written
  # @return self
  def <<(data)
    @deflater.deflate(data) { |chunk| @io << chunk }
    self
  end

  # Returns the amount of data received for writing, the amount of
  # compressed data written and the CRC32 checksum. The return value
  # can be directly used as the argument to {Streamer#update_last_entry_and_write_data_descriptor}
  #
  # @return [Hash] a hash of `{crc32, compressed_size, uncompressed_size}`
  def close
    @io << @deflater.finish until @deflater.finished?
    @io.close
  ensure
    @deflater.close
  end
end
