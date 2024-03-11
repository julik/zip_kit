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
    # The output enumerator yields chunks of bytes generated from ZipKit. Instantiating it
    # first will also validate the Streamer options.
    output_enum = ZipKit::OutputEnumerator.new(**zip_streamer_options, &zip_streaming_blk)

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

    headers = output_enum.streaming_http_headers

    # In rare circumstances (such as the app using Rack::ContentLength - which should normally
    # not be used allow the user to force the use of the chunked encoding
    if use_chunked_transfer_encoding
      output_enum = ZipKit::RackChunkedBody.new(output_enum)
      headers["Transfer-Encoding"] = "chunked"
    end

    response.headers.merge!(headers)
    self.response_body = output_enum
  end
end
