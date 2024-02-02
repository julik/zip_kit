module ChunkedEncoding
  def decode_chunked_encoding(io)
    io.rewind
    # Lifted from Net::HTTP mostly
    StringIO.new.binmode.tap do |dest|
      begin
        loop do
          line = io.readline
          hexlen = line.slice(/[0-9a-fA-F]+/)
          len = hexlen.hex
          break if len == 0 # Terminator (hex 0 followed by \r\n)

          dest.write(io.read(len))
          io.read(2)   # \r\n
        end
      rescue EOFError
        dest.rewind
      end
    end
  end
end
