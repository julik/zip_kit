# frozen_string_literal: true

require "zlib"

# Will be used to pick whether to store a file in the `stored` or
# `deflated` mode, by compressing the first N bytes of the file and
# comparing the stored and deflated data sizes. If deflate produces
# a sizable compression gain for this data, it will create a deflated
# file inside the ZIP archive. If the file doesn't compress well, it
# will use the "stored" mode for the entry. About 128KB of the
# file will be buffered to pick the appropriate storage mode. The
# Heuristic will call either `write_stored_file` or `write_deflated_file`
# on the Streamer passed into it once it knows which compression
# method should be applied
class ZipKit::Streamer::Heuristic < ZipKit::Streamer::Writable
  include ZipKit::ZlibCleanup

  BYTES_WRITTEN_THRESHOLD = 128 * 1024
  MINIMUM_VIABLE_COMPRESSION = 0.75

  def initialize(streamer, filename, **write_file_options)
    @streamer = streamer
    @filename = filename
    @write_file_options = write_file_options

    @buf = StringIO.new.binmode
    @deflater = ::Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -::Zlib::MAX_WBITS)
    @bytes_deflated = 0

    @winner = nil
    @started_closing = false
  end

  def <<(bytes)
    if @winner
      @winner << bytes
    else
      @buf << bytes
      @deflater.deflate(bytes) { |chunk| @bytes_deflated += chunk.bytesize }
      decide if @buf.size > BYTES_WRITTEN_THRESHOLD
    end
    self
  end

  def close
    return if @started_closing
    @started_closing = true # started_closing because an exception may get raised inside close(), as we add an entry there

    decide unless @winner
    @winner.close
  end

  def release_resources_on_failure!
    safely_dispose_of_incomplete_deflater(@deflater)
    @winner&.release_resources_on_failure!
  end

  private def decide
    # Finish and then close the deflater - it has likely buffered some data
    @bytes_deflated += @deflater.finish.bytesize until @deflater.finished?

    # If the deflated version is smaller than the stored one
    # - use deflate, otherwise stored
    ratio = @bytes_deflated / @buf.size.to_f
    @winner = if ratio <= MINIMUM_VIABLE_COMPRESSION
      @streamer.write_deflated_file(@filename, **@write_file_options)
    else
      @streamer.write_stored_file(@filename, **@write_file_options)
    end

    # Copy the buffered uncompressed data into the newly initialized writable
    @buf.rewind
    IO.copy_stream(@buf, @winner)
    @buf.truncate(0)
  ensure
    @deflater.close
  end
end
