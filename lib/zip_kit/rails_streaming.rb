# frozen_string_literal: true

# Should be included into a Rails controller for easy ZIP output from any action.
module ZipKit::RailsStreaming
  # Opens a {ZipKit::Streamer} and yields it to the caller. The output of the streamer
  # gets automatically forwarded to the Rails response stream. When the output completes,
  # the Rails response stream is going to be closed automatically.
  # @param filename[String] name of the file for the Content-Disposition header
  # @param type[String] the content type (MIME type) of the archive being output
  # @param use_chunked_transfer_encoding[Boolean] whether to forcibly encode output as chunked. Normally you should not need this.
  # @param zip_streamer_options[Hash] options that will be passed to the Streamer.
  #     See {ZipKit::Streamer#initialize} for the full list of options.
  # @yieldparam [ZipKit::Streamer] the streamer that can be written to
  # @return [ZipKit::OutputEnumerator] The output enumerator assigned to the response body
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
    output_enum = ZipKit::OutputEnumerator.new(**zip_streamer_options, &zip_streaming_blk)

    # Time for some branching, which mostly has to do with the 999 flavours of
    # "how to make both Rails and Rack stream"
    if self.class.ancestors.include?(ActionController::Live)
      # If this controller includes Live it will not work correctly with a Rack
      # response body assignment - we need to write into the Live output stream instead
      begin
        output_enum.each { |bytes| response.stream.write(bytes) }
      ensure
        response.stream.close
      end
    elsif use_chunked_transfer_encoding
      # Chunked encoding may be forced if, for example, you _need_ to bypass Rack::ContentLength.
      # Rack::ContentLength is normally not in a Rails middleware stack, but it might get
      # introduced unintentionally - for example, "rackup" adds the ContentLength middleware for you.
      # There is a recommendation to leave the chunked encoding to the app server, so that servers
      # that support HTTP/2 can use native framing and not have to deal with the chunked encoding,
      # see https://github.com/julik/zip_kit/issues/7
      # But it is not to be excluded that a user may need to force the chunked encoding to bypass
      # some especially pesky Rack middleware that just would not cooperate. Those include
      # Rack::MiniProfiler and the above-mentioned Rack::ContentLength.
      response.headers["Transfer-Encoding"] = "chunked"
      self.response_body = ZipKit::RackChunkedBody.new(output_enum)
    else
      # Stream using a Rack body assigned to the ActionController response body, without
      # doing explicit chunked encoding. See above for the reasoning.
      self.response_body = output_enum
    end
  end
end
