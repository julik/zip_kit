require_relative "../../spec_helper"

describe ZipKit::Streamer::Heuristic do
  it "does not raise with small UTF-8 strings getting passed" do
    output = StringIO.new
    streamer = ZipKit::Streamer.new(output)

    subject = described_class.new(streamer, "somefile.bin")
    expect {
      ((64 * 1024) + 2).times { subject << "é" }
      subject.close
    }.not_to raise_error
  end
end
