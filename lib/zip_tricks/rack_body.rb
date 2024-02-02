# frozen_string_literal: true

# RackBody is actually just another use of the OutputEnumerator, since a Rack body
# object must support `#each` yielding successive binary strings.
#
# The RackBody can also wrap itself in a chunking wrapper. This is for outputting
# a ZIP archive from Rails or Rack, where an object responding to `each` is required
# which yields Strings. You can return a ZIP archive from Rack like so:
#
#     iterable_zip_body = ZipTricks::RackBody.new do | streamer |
#       streamer.write_deflated_file('big.csv') do |sink|
#         CSV(sink) do |csv_writer|
#           csv_writer << Person.column_names
#           Person.all.find_each do |person|
#             csv_writer << person.attributes.values
#           end
#         end
#       end
#     end
#
#     headers = {
#       "Last-Modified" => Time.now.httpdate, # disables Rack::ETag
#       "Content-Type" => "application/zip",
#       "Transfer-Encoding" => "chunked",
#       "X-Accel-Buffering" => "no" # disables buffering in nginx/GCP
#     }
#
#     [200, headers, iterable_zip_body.to_chunked]
class ZipTricks::RackBody < ZipTricks::OutputEnumerator
  # A body wrapper that emits chunked responses, creating valid
  # Transfer-Encoding::Chunked HTTP response body. This is copied from Rack::Chunked::Body,
  # because Rack is not going to include that class after version 3.x
  # Rails has a substitute class for this inside ActionController::Streaming,
  # but that module is a private constant in the Rails codebase, and is thus
  # considered "private" from the Rails standpoint. It is not that much code to
  # carry, so we copy it into our code.
  class Chunked
    TERM = "\r\n"
    TAIL = "0#{TERM}"

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

  # Returns the output enumerator wrapped in Chunked. The returned object will
  # yield appropriately length-prefixed and terminated strings on every call
  # to `each'.
  #
  # @return [Chunked]
  def to_chunked
    Chunked.new(self)
  end
end
