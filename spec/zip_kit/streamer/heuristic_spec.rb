require_relative "../../spec_helper"

describe ZipKit::Streamer::Heuristic do
  it "does not allow non-binary encoded Strings to be passed downstream" do
    output = StringIO.new
    streamer = ZipKit::Streamer.new(output)
    
    subject = described_class.new(streamer, "somefile.bin")
    ((64 * 1024) + 2).times { subject << "é" }
  end
end
