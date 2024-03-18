# frozen_string_literal: true

# Acts as a converter between callers which send data to the `#<<` method (such as all the ZipKit
# writer methods, which push onto anything), and a given block. Every time `#<<` gets called on the BlockWrite,
# the block given to the constructor will be called with the same argument. ZipKit uses this object
# when integrating with Rack and in the OutputEnumerator. Normally you wouldn't need to use it manually but
# you always can. BlockWrite will also ensure the binary string encoding is forced onto any string
# that passes through it.
#
# For example, you can create a Rack response body like so:
#
#     class MyRackResponse
#       def each
#         writer = ZipKit::BlockWrite.new {|chunk| yield(chunk) }
#         writer << "Hello" << "world" << "!"
#       end
#     end
#     [200, {}, MyRackResponse.new]
class ZipKit::BlockWrite
  include ZipKit::WriteShovel

  # Creates a new BlockWrite.
  #
  # @param block The block that will be called when this object receives the `<<` message
  # @yieldparam bytes[String] A string in binary encoding which has just been written into the object
  def initialize(&block)
    @block = block
  end

  # Make sure those methods raise outright
  %i[seek pos= to_s].each do |m|
    define_method(m) do |*_args|
      raise "#{m} not supported - this IO adapter is non-rewindable"
    end
  end

  # Sends a string through to the block stored in the BlockWrite.
  #
  # @param buf[String] the string to write. Note that a zero-length String
  #    will not be forwarded to the block, as it has special meaning when used
  #    with chunked encoding (it indicates the end of the stream).
  # @return [ZipKit::BlockWrite]
  def <<(buf)
    # Zero-size output has a special meaning  when using chunked encoding
    return if buf.nil? || buf.bytesize.zero?

    @block.call(buf.b)
    self
  end
end
