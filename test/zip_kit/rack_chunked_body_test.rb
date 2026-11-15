require "test_helper"

class RackChunkedBodyTest < TestCase
  test "applies a chunked encoding" do
    iterable = ["foo", "bar", "baz"].each
    body = ZipKit::RackChunkedBody.new(iterable)

    output_lines = []
    body.each do |bytes|
      output_lines << bytes
    end

    assert_equal [
      "3\r\nfoo\r\n",
      "3\r\nbar\r\n",
      "3\r\nbaz\r\n",
      "0\r\n",
      "\r\n"
    ], output_lines
  end
end
