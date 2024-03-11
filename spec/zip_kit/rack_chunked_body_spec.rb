require "spec_helper"

# This is a deprecated class and will be removed in zip_kit 7.x
describe ZipKit::RackChunkedBody do
  it "applies a chunked encoding" do
    iterable = ["foo", "bar", "baz"].each
    body = ZipKit::RackChunkedBody.new(iterable)

    output_lines = []
    body.each do |bytes|
      output_lines << bytes
    end

    expect(output_lines).to eq([
      "3\r\nfoo\r\n",
      "3\r\nbar\r\n",
      "3\r\nbaz\r\n",
      "0\r\n",
      "\r\n"
    ])
  end
end
