# frozen_string_literal: true

# A lot of objects in ZipKit accept bytes that may be sent
# to the `<<` operator (the "shovel" operator). This is in the tradition
# of late Jim Weirich and his Builder gem. In [this presentation](https://youtu.be/1BVFlvRPZVM?t=2403)
# he justifies this design very eloquently. In ZipKit we follow this example.
# However, there is a number of methods in Ruby - including the standard library -
# which expect your object to implement the `write` method instead. Since the `write`
# method can be expressed in terms of the `<<` method, why not allow all ZipKit
# "IO-ish" things to also respond to `write`? This is what this module does.
# Jim would be proud. We miss you, Jim.
module ZipKit::WriteShovel
  # Writes the given data to the output stream. Allows the object to be used as
  # a target for `IO.copy_stream(from, to)`
  #
  # @param bytes[String] the binary string to write (part of the uncompressed file)
  # @return [Integer] the number of bytes written (will always be the bytesize of `bytes`)
  def write(bytes)
    self << bytes
    bytes.bytesize
  end
end
