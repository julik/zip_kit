# A lot of objects in ZipTricks accept bytes that may be sent
# to the `<<` operator (the "shovel" operator). This is in the tradition
# of late Jim Weirich and his Builder gem. In [this presentation](https://youtu.be/1BVFlvRPZVM?t=2403)
# he justifies this design very eloquently. In ZipTricks we follow this example.
# However, there is a number of methods in Ruby - including the standard library -
# which expect your object to implement the `write` method instead. Since the `write`
# method can be expressed in terms of the `<<` method, why not allow all ZipTricks
# "IO-ish" things to also respond to `write`? This is what this module does.
# Jim would be proud. We miss you, Jim.
module ZipTricks::WriteShovel
  # Writes the given data to the output stream. Allows the object to be used as
  # a target for `IO.copy_stream(from, to)`
  #
  # @param d[String] the binary string to write (part of the uncompressed file)
  # @return [Fixnum] the number of bytes written
  def write(bytes)
    self << bytes
    bytes.bytesize
  end
end
