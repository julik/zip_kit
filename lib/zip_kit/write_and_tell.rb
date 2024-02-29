# frozen_string_literal: true

# A tiny wrapper over any object that supports :<<.
# Adds :tell and :advance_position_by. This is needed for write destinations
# which do not respond to `#pos` or `#tell`. A lot of ZIP archive format parts
# include "offsets in archive" - a byte offset from the start of file. Keeping
# track of this value is what this object will do. It also allows "advancing"
# this value if data gets written using a bypass (such as `IO#sendfile`)
class ZipKit::WriteAndTell
  include ZipKit::WriteShovel

  def initialize(io)
    @io = io
    @pos = 0
    # Some objects (such as ActionController::Live `stream` object) cannot be "pushed" into
    # using the :<< operator, but only support `write`. For ease we add a small shim in that case instead of having
    # the user abstract it themselves.
    @use_write = !io.respond_to?(:<<)
  end

  def <<(bytes)
    return self if bytes.nil?
    if @use_write
      @io.write(bytes.b)
    else
      @io << bytes.b
    end

    @pos += bytes.bytesize
    self
  end

  def advance_position_by(num_bytes)
    @pos += num_bytes
  end

  def tell
    @pos
  end
end
