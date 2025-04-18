# frozen_string_literal: true

# Gets yielded from the writing methods of the Streamer
# and accepts the data being written into the ZIP for deflate
# or stored modes. Can be used as a destination for `IO.copy_stream`
#
#    IO.copy_stream(File.open('source.bin', 'rb), writable)
class ZipKit::Streamer::Writable
  include ZipKit::WriteShovel

  # Initializes a new Writable with the object it delegates the writes to.
  # Normally you would not need to use this method directly
  def initialize(streamer, writer)
    @streamer = streamer
    @writer = writer
    @closed = false
  end

  # Writes the given data to the output stream
  #
  # @param string[String] the string to write (part of the uncompressed file)
  # @return [self]
  def <<(string)
    raise "Trying to write to a closed Writable" if @closed
    @writer << string.b
    self
  end

  # Flushes the writer and recovers the CRC32/size values. It then calls
  # `update_last_entry_and_write_data_descriptor` on the given Streamer.
  def close
    return if @closed
    @streamer.update_last_entry_and_write_data_descriptor(**@writer.finish)
    @closed = true
  end

  def release_resources_on_failure!
    return if @closed
    @closed = true
    @writer.release_resources_on_failure!
  end
end
