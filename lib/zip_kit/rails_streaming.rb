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
    chunk_yielder = ZipKit::OutputEnumerator.new(**zip_streamer_options, &zip_streaming_blk)

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

    headers, rack_body = chunk_yielder.to_headers_and_rack_response_body(request.env)

    # Set the "particular" streaming headers
    response.headers.merge!(headers)
    self.response_body = rack_body
  end
end
