# frozen_string_literal: true

module ZipKit::ZlibCleanup
  # This method is used to flush and close the native zlib handles
  # should an archiving routine encounter an error. This is necessary,
  # since otherwise unclosed deflaters may hang around in memory
  # indefinitely, creating leaks.
  #
  # @param [Zlib::Deflater?]deflater the deflater to safely finish and close
  # @return void
  def safely_dispose_of_incomplete_deflater(deflater)
    return unless deflater

    # It can be a bit tricky to close and dealloc the deflater correctly.
    # We want to do the right things for it to be GCd, including the
    # native zlib handle. Also, leaving zlib handles dangling around
    # creates warnings with "...with N bytes remaining to read", which are an
    # eyesore. But they are there for a reason - so that we don't forget to do
    # exactly this.
    if !deflater.closed? && !deflater.finished?
      deflater.finish until deflater.finished?
    end
    deflater.close unless deflater.closed?
  end
end
