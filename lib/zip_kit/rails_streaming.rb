# frozen_string_literal: true

# Should be included into a Rails controller for easy ZIP output from any action.
module ZipKit::RailsStreaming
  # Opens a {ZipKit::Streamer} and yields it to the caller. The output of the streamer
  # gets automatically forwarded to the Rails response stream. When the output completes,
  # the Rails response stream is going to be closed automatically.
  #
  # Note that there is an important difference in how this method works, depending whether
  # you use it in a controller which includes `ActionController::Live` vs. one that does not.
  # With a standard `ActionController` this method will assign a response body, but streaming
  # will begin when your action method returns. With `ActionController::Live` the streaming
  # will begin immediately, before the method returns. In all other aspects the method should
  # stream correctly in both types of controllers.
  #
  # If you encounter buffering (streaming does not start for a very long time) you probably
  # have a piece of Rack middleware in your stack which buffers. Known offenders are `Rack::ContentLength`,
  # `Rack::MiniProfiler` and `Rack::ETag`. ZipKit will try to work around these but it is not
  # always possible. If you encounter buffering, examine your middleware stack and try to suss
  # out whether any middleware might be buffering. You can also try setting `use_chunked_transfer_encoding`
  # to `true` - this is not recommended but sometimes necessary, for example to bypass `Rack::ContentLength`.
  #
  # @param filename[String] name of the file for the Content-Disposition header
  # @param type[String] the content type (MIME type) of the archive being output
  # @param use_chunked_transfer_encoding[Boolean] whether to forcibly encode output as chunked. Normally you should not need this.
  # @param zip_streamer_options[Hash] options that will be passed to the Streamer.
  #     See {ZipKit::Streamer#initialize} for the full list of options.
  # @yieldparam [ZipKit::Streamer] the streamer that can be written to
  # @return [Boolean] always returns true
  def zip_kit_stream(filename: "download.zip", type: "application/zip", use_chunked_transfer_encoding: false, **zip_streamer_options, &zip_streaming_blk)
    # We want some common headers for file sending. Rails will also set
    # self.sending_file = true for us when we call send_file_headers!
    send_file_headers!(type: type, filename: filename)

    # Check for the proxy configuration first. This is the first common misconfiguration which destroys streaming -
    # since HTTP 1.0 does not support chunked responses we need to revert to buffering. The issue though is that
    # this reversion happens silently and it is usually not clear at all why streaming does not work. So let's at
    # the very least print it to the Rails log.
    if request.get_header("HTTP_VERSION") == "HTTP/1.0"
      logger&.warn { "The downstream HTTP proxy/LB insists on HTTP/1.0 protocol, ZIP response will be buffered." }
    end

    headers = ZipKit::OutputEnumerator.streaming_http_headers
    response.headers.merge!(headers)

    # The output enumerator yields chunks of bytes generated from the Streamer,
    # with some buffering
    rack_zip_body = ZipKit::OutputEnumerator.new(**zip_streamer_options, &zip_streaming_blk)

    # Chunked encoding may be forced if, for example, you _need_ to bypass Rack::ContentLength.
    # Rack::ContentLength is normally not in a Rails middleware stack, but it might get
    # introduced unintentionally - for example, "rackup" adds the ContentLength middleware for you.
    # There is a recommendation to leave the chunked encoding to the app server, so that servers
    # that support HTTP/2 can use native framing and not have to deal with the chunked encoding,
    # see https://github.com/julik/zip_kit/issues/7
    # But it is not to be excluded that a user may need to force the chunked encoding to bypass
    # some especially pesky Rack middleware that just would not cooperate. Those include
    # Rack::MiniProfiler and the above-mentioned Rack::ContentLength.
    if use_chunked_transfer_encoding
      response.headers["Transfer-Encoding"] = "chunked"
      rack_zip_body = ZipKit::RackChunkedBody.new(rack_zip_body)
    end

    # Time for some branching, which mostly has to do with the 999 flavours of
    # "how to make both Rails and Rack stream"
    if self.class.ancestors.include?(ActionController::Live)
      # If this controller includes Live it will not work correctly with a Rack
      # response body assignment - the action will just hang. We need to read out the response
      # body ourselves and write it into the Rails stream.
      begin
        rack_zip_body.each { |bytes| response.stream.write(bytes) }
      ensure
        response.stream.close
      end
    else
      # Stream using a Rack body assigned to the ActionController response body
      self.response_body = rack_zip_body
    end

    true
  end
end
