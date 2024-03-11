# frozen_string_literal: true

# Contains a file handle which can be closed once the response finishes sending.
# It supports `to_path` so that `Rack::Sendfile` can intercept it.
# This class is deprecated and is going to be removed in zip_kit 7.x
# @api deprecated
class ZipKit::RackTempfileBody
  TEMPFILE_NAME_PREFIX = "zip-tricks-tf-body-"
  attr_reader :tempfile

  # @param body[#each] the enumerable that yields bytes, usually a `OutputEnumerator`.
  #   The `body` will be read in full immediately and closed.
  def initialize(env, body)
    @tempfile = Tempfile.new(TEMPFILE_NAME_PREFIX)
    # Rack::TempfileReaper calls close! on tempfiles which get buffered
    # We wil assume that it works fine with Rack::Sendfile (i.e. the path
    # to the file getting served gets used before we unlink the tempfile)
    env["rack.tempfiles"] ||= []
    env["rack.tempfiles"] << @tempfile

    @tempfile.binmode
    @body = body
    @did_flush = false
  end

  # Returns the size of the contained `Tempfile` so that a correct
  # Content-Length header can be set
  #
  # @return [Integer]
  def size
    flush
    @tempfile.size
  end

  # Returns the path to the `Tempfile`, so that Rack::Sendfile can send this response
  # using the downstream webserver
  #
  # @return [String]
  def to_path
    flush
    @tempfile.to_path
  end

  # Stream the file's contents if `Rack::Sendfile` isn't present.
  #
  # @return [void]
  def each
    flush
    while (chunk = @tempfile.read(16384))
      yield chunk
    end
  end

  private

  def flush
    if !@did_flush
      @body.each { |bytes| @tempfile << bytes }
      @did_flush = true
    end
    @tempfile.rewind
  end
end
