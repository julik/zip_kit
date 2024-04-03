# frozen_string_literal: true

# Sends writes to the given `io`, and also registers all the data passing
# through it in a CRC32 checksum calculator. Is made to be completely
# interchangeable with the DeflatedWriter in terms of interface.
class ZipKit::Streamer::StoredWriter
  def initialize(io)
    @io = io
  end

  # Writes the given data to the contained IO object.
  #
  # @param data[String] data to be written
  # @return self
  def <<(data)
    @io << data
    self
  end

  # Returns the amount of data written and the CRC32 checksum. The return value
  # can be directly used as the argument to {Streamer#update_last_entry_and_write_data_descriptor}
  #
  # @return [Hash] a hash of `{crc32, compressed_size, uncompressed_size}`
  def close
  end
end
