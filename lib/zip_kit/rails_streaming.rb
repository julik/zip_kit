# frozen_string_literal: true

# Should be included into a Rails controller for easy ZIP output from any action.
module ZipKit::RailsStreaming
  # Opens a {ZipKit::Streamer} and yields it to the caller. The output of the streamer
  # gets automatically forwarded to the Rails response stream. When the output completes,
  # the Rails response stream is going to be closed automatically.
  # @param filename[String] name of the file for the Content-Disposition header
  # @param type[String] the content type (MIME type) of the archive being output
  # @param zip_streamer_options[Hash] options that will be passed to the Streamer.
  #     See {ZipKit::Streamer#initialize} for the full list of options.
  # @yield [Streamer] the streamer that can be written to
  # @return [ZipKit::OutputEnumerator] The output enumerator assigned to the response body
  def zip_kit_stream(filename: "download.zip", type: "application/zip", **zip_streamer_options, &zip_streaming_blk)
    # The output enumerator yields chunks of bytes generated from ZipKit. Instantiating it
    # first will also validate the Streamer options.
    chunk_yielder = ZipKit::RackBody.new(**zip_streamer_options, &zip_streaming_blk)

    # We want some common headers for file sending. Rails will also set
    # self.sending_file = true for us when we call send_file_headers!
    send_file_headers!(type: type, filename: filename)

    # We need to ensure Rack::ETag does not suddenly start buffering us, see
    # https://github.com/rack/rack/issues/1619#issuecomment-606315714
    # Set this even when not streaming for consistency. The fact that there would be
    # a weak ETag generated would mean that the middleware buffers, so we have tests for that.
    response.headers["Last-Modified"] = Time.now.httpdate

    # Make sure Rack::Deflater does not touch our response body either, see
    # https://github.com/felixbuenemann/xlsxtream/issues/14#issuecomment-529569548
    response.headers["Content-Encoding"] = "identity"

    # Check for the proxy configuration first. This is the first common misconfiguration which destroys streaming -
    # since HTTP 1.0 does not support chunked responses we need to revert to buffering. The issue though is that
    # this reversion happens silently and it is usually not clear at all why streaming does not work. So let's at
    # the very least print it to the Rails log.
    if request.get_header("HTTP_VERSION") == "HTTP/1.0"
      logger&.warn { "The downstream HTTP proxy/LB insists on HTTP/1.0 protocol, ZIP response will be buffered." }

      # Buffer the ZIP into a tempfile so that we do not iterate over the ZIP-generating block twice
      tempfile_body = chunk_yielder.to_tempfile_body(request.env)

      # Set the content length so that Rack::ContentLength disengages
      response.headers["Content-Length"] = tempfile_body.size.to_s

      # Assign the tempfile body. Since it supports #to_path it will likely be picked up by Rack::Sendfile
      self.response_body = tempfile_body
    else
      # Disable buffering for both nginx and Google Load Balancer, see
      # https://cloud.google.com/appengine/docs/flexible/how-requests-are-handled?tab=python#x-accel-buffering
      response.headers["X-Accel-Buffering"] = "no"

      # Make sure Rack::ContentLength does not try to compute a content length,
      # and remove the one already set
      response.headers["Transfer-Encoding"] = "chunked"
      response.headers.delete("Content-Length")

      self.response_body = chunk_yielder.to_chunked
    end
  end
end
