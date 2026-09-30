# frozen_string_literal: true

# Some operations (such as CRC32) benefit when they are performed
# on larger chunks of data. In certain use cases, it is possible that
# the consumer of ZipKit is going to be writing small chunks
# in rapid succession, so CRC32 is going to have to perform a lot of
# CRC32 combine operations - and this adds up. Since the CRC32 value
# is usually not needed until the complete output has completed
# we can buffer at least some amount of data before computing CRC32 over it.
# We also use this buffer for output via Rack, where some amount of buffering
# helps reduce the number of syscalls made by the webserver. ZipKit performs
# lots of very small writes, and some degree of speedup (about 20%) can be achieved
# with a buffer of a few KB.
#
# The WriteBuffer is also useful in front of a `write_file` / `write_deflated_file` writable
# if you are going to be appending lots of tiny strings (like XML fragments) to it. Every write
# into a writable goes through Zlib separately, so coalescing those writes into bigger chunks
# is much faster.
#
# All strings appended to the WriteBuffer are appended as bytes, and the buffer String
# given to the writable is always in binary encoding (`Encoding::BINARY`). You can therefore mix
# binary strings and strings in other encodings (for instance UTF-8 with non-ASCII characters)
# without getting an `Encoding::CompatibilityError`. No intermediate copies of the strings
# you append (like `String#b` would create) are made.
#
# Note that there is no guarantee that the write buffer is going to flush at exactly
# the given `buffer_size`. The buffer gets flushed when the next write would make it exceed
# `buffer_size`, so the chunks it outputs are usually a bit smaller than that (strings with
# multibyte characters can make it go slightly over). For writes of `buffer_size` or larger
# it will first `flush` and then write through the oversized chunk, without buffering it.
# This helps conserve memory. Also note that the buffer will *not* duplicate strings for you
# and *will* yield the same buffer String over and over, so if you are storing it in an
# Array you might need to duplicate it.
#
# Note also that the WriteBuffer assumes that the object it `<<`-writes into is going
# to **consume** in some way the string that it passes in. After the `<<` method returns,
# the WriteBuffer will be cleared, and it passes the same String reference on every call
# to `<<`. Therefore, if you need to retain the output of the WriteBuffer in, say, an Array,
# you might need to `.dup` the `String` it gives you.
class ZipKit::WriteBuffer
  # String#append_as_bytes (Ruby 3.4+) appends the bytes of the string without any encoding
  # negotiation, so the buffer always stays binary. Without it we use String#<<, see `append_bytes`.
  APPEND_AS_BYTES = String.instance_methods.include?(:append_as_bytes)

  # Creates a new WriteBuffer bypassing into a given writable object
  #
  # @param writable[#<<] An object that responds to `#<<` with a String as argument
  # @param buffer_size[Integer] How many bytes to buffer
  def initialize(writable, buffer_size)
    # No capacity gets preallocated. String#clear releases the memory held by the String,
    # so after the first flush the buffer would have to grow again anyway - and many
    # WriteBuffers (like the ones used for the CRC32 of small ZIP entries) never fill up.
    @buf = "".b
    @buffer_size = buffer_size
    @writable = writable
  end

  # Appends the given data to the write buffer, and flushes the buffer into the
  # writable if the buffer size exceeds the `buffer_size` given at initialization
  #
  # @param string[String] data to be written
  # @return self
  def <<(string)
    if @buf.bytesize + string.bytesize < @buffer_size
      APPEND_AS_BYTES ? @buf.append_as_bytes(string) : append_bytes(string)
    elsif string.bytesize >= @buffer_size
      flush
      # String#b does not copy the bytes of a large String, the new String shares them
      @writable << string.b
    else
      flush if @buf.bytesize + string.bytesize > @buffer_size
      append_bytes(string)
      flush if @buf.bytesize >= @buffer_size
    end
    self
  end

  # Explicitly flushes the buffer if it contains anything
  #
  # @return self
  def flush
    unless @buf.empty?
      # force_encoding does not copy the String, it only changes its encoding
      @writable << @buf.force_encoding(Encoding::BINARY)
      @buf.clear
    end
    self
  end

  # `flush!` was renamed to `flush` but we preserve this method for backwards compatibility
  alias_method :flush!, :flush

  private

  # Appends the bytes of the string without copying it. Without String#append_as_bytes (Ruby < 3.4)
  # String#<< is used, which may change the encoding of the buffer or raise if the encodings are
  # incompatible - in that case we append the bytes of the string instead. The buffer is forced
  # back into binary before it is handed to the writable, see `flush`.
  def append_bytes(string)
    return @buf.append_as_bytes(string) if APPEND_AS_BYTES

    @buf << string
  rescue Encoding::CompatibilityError
    @buf.force_encoding(Encoding::BINARY)
    @buf << string.b
  end
end
