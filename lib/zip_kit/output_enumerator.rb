# frozen_string_literal: true

require "time" # for .httpdate

# The output enumerator makes it possible to "pull" from a ZipKit streamer
# object instead of having it "push" writes to you. It will "stash" the block which
# writes the ZIP archive through the streamer, and when you call `each` on the Enumerator
# it will yield you the bytes the block writes. Since it is an enumerator you can
# use `next` to take chunks written by the ZipKit streamer one by one. It can be very
# convenient when you need to segment your ZIP output into bigger chunks for, say,
# uploading them to a cloud storage provider such as S3.
#
# Another use of the `OutputEnumerator` is as a Rack response body - since a Rack
# response body object must support `#each` yielding successive binary strings.
# Which is exactly what `OutputEnumerator` does.
#
# The enumerator can provide you some more conveinences for HTTP output - correct streaming
# headers and a body with chunked transfer encoding.
#
#     iterable_zip_body = ZipKit::OutputEnumerator.new do | streamer |
#       streamer.write_file('big.csv') do |sink|
#         CSV(sink) do |csv_writer|
#           csv_writer << Person.column_names
#           Person.all.find_each do |person|
#             csv_writer << person.attributes.values
#           end
#         end
#       end
#     end
#
# You can grab the headers one usually needs for streaming from `#streaming_http_headers`:
#
#     [200, iterable_zip_body.streaming_http_headers, iterable_zip_body]
#
# to bypass things like `Rack::ETag` and the nginx buffering.
class ZipKit::OutputEnumerator
  DEFAULT_WRITE_BUFFER_SIZE = 64 * 1024

  # Creates a new OutputEnumerator enumerator. The enumerator can be read from using `each`,
  # and the creation of the ZIP is in lockstep with the caller calling `each` on the returned
  # output enumerator object. This can be used when the calling program wants to stream the
  # output of the ZIP archive and throttle that output, or split it into chunks, or use it
  # as a generator.
  #
  # For example:
  #
  #     # The block given to {output_enum} won't be executed immediately - rather it
  #     # will only start to execute when the caller starts to read from the output
  #     # by calling `each`
  #     body = ::ZipKit::OutputEnumerator.new(writer: CustomWriter) do |streamer|
  #       streamer.add_stored_entry(filename: 'large.tif', size: 1289894, crc32: 198210)
  #       streamer << large_file.read(1024*1024) until large_file.eof?
  #       ...
  #     end
  #
  #     body.each do |bin_string|
  #       # Send the output somewhere, buffer it in a file etc.
  #       # The block passed into `initialize` will only start executing once `#each`
  #       # is called
  #       ...
  #     end
  #
  # @param kwargs_for_new [Hash] keyword arguments for {Streamer.new}
  # @return [ZipKit::OutputEnumerator] the enumerator you can read bytestrings of the ZIP from by calling `each`
  #
  # @param streamer_options[Hash] options for Streamer, see {ZipKit::Streamer.new}
  # @param write_buffer_size[Integer] By default all ZipKit writes are unbuffered. For output to sockets
  #     it is beneficial to bulkify those writes so that they are roughly sized to a socket buffer chunk. This
  #     object will bulkify writes for you in this way (so `each` will yield not on every call to `<<` from the Streamer
  #     but at block size boundaries or greater). Set it to 0 for unbuffered writes.
  # @param blk a block that will receive the Streamer object when executing. The block will not be executed
  #     immediately but only once `each` is called on the OutputEnumerator
  def initialize(write_buffer_size: DEFAULT_WRITE_BUFFER_SIZE, **streamer_options, &blk)
    @streamer_options = streamer_options.to_h
    @bufsize = write_buffer_size.to_i
    @archiving_block = blk
  end

  # Executes the block given to the constructor with a {ZipKit::Streamer}
  # and passes each written chunk to the block given to the method. This allows one
  # to "take" output of the ZIP piecewise. If called without a block will return an Enumerator
  # that you can pull data from using `next`.
  #
  # **NOTE** Because the `WriteBuffer` inside this object can reuse the buffer, it is important
  #    that the `String` that is yielded **either** gets consumed eagerly (written byte-by-byte somewhere, or `#dup`-ed)
  #    since the write buffer will clear it after your block returns. If you expand this Enumerator
  #    eagerly into an Array you might notice that a lot of the segments of your ZIP output are
  #    empty - this means that you need to duplicate them.
  #
  # @yield [String] a chunk of the ZIP output in binary encoding
  def each
    if block_given?
      block_write = ZipKit::BlockWrite.new { |chunk| yield(chunk) }
      buffer = ZipKit::WriteBuffer.new(block_write, @bufsize)
      ZipKit::Streamer.open(buffer, **@streamer_options, &@archiving_block)
      buffer.flush
    else
      enum_for(:each)
    end
  end

  # Returns a Hash of HTTP response headers you are likely to need to have your response stream correctly.
  #
  # @return [Hash]
  def streaming_http_headers
    _headers = {
      # We need to ensure Rack::ETag does not suddenly start buffering us, see
      # https://github.com/rack/rack/issues/1619#issuecomment-606315714
      # Set this even when not streaming for consistency. The fact that there would be
      # a weak ETag generated would mean that the middleware buffers, so we have tests for that.
      "Last-Modified" => Time.now.httpdate,
      # Make sure Rack::Deflater does not touch our response body either, see
      # https://github.com/felixbuenemann/xlsxtream/issues/14#issuecomment-529569548
      "Content-Encoding" => "identity",
      # Disable buffering for both nginx and Google Load Balancer, see
      # https://cloud.google.com/appengine/docs/flexible/how-requests-are-handled?tab=python#x-accel-buffering
      "X-Accel-Buffering" => "no",
      # Set the correct content type. This should be overridden if you need to
      # serve things such as EPubs and other derived ZIP formats.
      "Content-Type" => "application/zip"
    }
  end

  # Returns a tuple of `headers, body` - headers are a `Hash` and the body is
  # an object that can be used as a Rack response body. This method used to accept arguments
  # but will now just ignore them.
  #
  # @return [Array]
  def to_headers_and_rack_response_body(*, **)
    [streaming_http_headers, self]
  end
end
