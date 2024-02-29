# frozen_string_literal: true

# RackBody is actually just another use of the OutputEnumerator, since a Rack body
# object must support `#each` yielding successive binary strings.
#
# The RackBody can also wrap itself in a chunking wrapper. This is for outputting
# a ZIP archive from Rails or Rack, where an object responding to `each` is required
# which yields Strings. You can return a ZIP archive from Rack like so:
#
#     iterable_zip_body = ZipKit::RackBody.new do | streamer |
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
# either as a `Transfer-Encoding: chunked` response (if your webserver supports it),

# which will give you true streaming capability:
#
#     chunked_body = iterable_zip_body.to_chunked
#     headers = {
#       "Last-Modified" => Time.now.httpdate, # disables Rack::ETag
#       "Content-Type" => "application/zip",
#       "Content-Disposition" => "attachment",
#       "Transfer-Encoding" => "chunked",
#       "X-Accel-Buffering" => "no" # disables buffering in nginx/GCP
#     }
#     [200, headers, chunked_body]
#
# or in a `TempfileBody` object which buffers the ZIP before output. Buffering has
# benefits if your webserver does not support anything beyound HTTP/1.0:
#
#     tf_body = iterable_zip_body.to_tempfile_body
#     headers = {
#       "Last-Modified" => Time.now.httpdate, # disables Rack::ETag
#       "Content-Type" => "application/zip",
#       "Content-Disposition" => "attachment",
#       "Content-Length" => tf_body.content_length,
#     }
#     [200, headers, tf_body]
class ZipKit::RackBody < ZipKit::OutputEnumerator
  # A body wrapper that emits chunked responses, creating valid
  # Transfer-Encoding::Chunked HTTP response body. This is copied from Rack::Chunked::Body,
  # because Rack is not going to include that class after version 3.x
  # Rails has a substitute class for this inside ActionController::Streaming,
  # but that module is a private constant in the Rails codebase, and is thus
  # considered "private" from the Rails standpoint. It is not that much code to
  # carry, so we copy it into our code.
  class ChunkedBody
    TERM = "\r\n"
    TAIL = "0#{TERM}"

    # @param body[#each] the enumerable that yields bytes, usually a `RackBody`
    def initialize(body)
      @body = body
    end

    # For each string yielded by the response body, yield
    # the element in chunked encoding - and finish off with a terminator
    def each
      term = TERM
      @body.each do |chunk|
        size = chunk.bytesize
        next if size == 0

        yield [size.to_s(16), term, chunk.b, term].join
      end
      yield TAIL
      yield term
    end
  end

  # Contains a file handle which can be closed once the response finishes sending.
  # It supports `to_path` so that `Rack::Sendfile` can intercept it
  class TempfileBody
    TEMPFILE_NAME_PREFIX = "zip-tricks-tf-body-"
    attr_reader :tempfile

    # @param body[#each] the enumerable that yields bytes, usually a `RackBody`.
    #   The `body` will be read in full immediately and closed.
    def initialize(env, body)
      @tempfile = Tempfile.new(TEMPFILE_NAME_PREFIX)
      # Rack::TempfileReaper calls close! on tempfiles which get buffered
      # We wil assume that it works fine with Rack::Sendfile (i.e. the path
      # to the file getting served gets used before we unlink the tempfile)
      env["rack.tempfiles"] ||= []
      env["rack.tempfiles"] << @tempfile

      @tempfile.binmode

      body.each { |bytes| @tempfile << bytes }
      body.close if body.respond_to?(:close)

      @tempfile.flush
    end

    # Returns the size of the contained `Tempfile` so that a correct
    # Content-Length header can be set
    #
    # @return [Integer]
    def size
      @tempfile.size
    end

    # Returns the path to the `Tempfile`, so that Rack::Sendfile can send this response
    # using the downstream webserver
    #
    # @return [String]
    def to_path
      @tempfile.to_path
    end

    # Stream the file's contents if `Rack::Sendfile` isn't present.
    #
    # @return [void]
    def each
      @tempfile.rewind
      while (chunk = @tempfile.read(16384))
        yield chunk
      end
    end
  end

  # Returns a Tempfile which has been generated. This is useful when serving buffered - as
  # when doing that we can preset the Content-Length of the response, so that Rack::ContentLength
  # does not iterate over the response twice. You may later elect to send that response using
  # the `Rack::File` middleware as well, which would give you `Range:` request support
  #
  # @param rack_env[Hash] the Rack request env
  # @return [Tempfile] the tempfile containing the ZIP in full
  def to_tempfile_body(rack_env)
    TempfileBody.new(rack_env, self)
  end

  # Returns the output enumerator wrapped in Chunked. The returned object will
  # yield appropriately length-prefixed and terminated strings on every call
  # to `each'.
  #
  # @return [Chunked]
  def to_chunked
    ChunkedBody.new(self)
  end
end
