# frozen_string_literal: true

# Is used internally by Streamer to keep track of entries in the archive during writing.
# Normally you will not have to use this class directly
class ZipKit::Streamer::Filler < Struct.new(:total_bytes_used)
  def filler?
    true
  end
end
