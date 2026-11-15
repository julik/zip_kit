require "test_helper"

class StreamerHeuristicTest < TestCase
  test "does not raise with small UTF-8 strings getting passed" do
    output = StringIO.new
    streamer = ZipKit::Streamer.new(output)

    heuristic = ZipKit::Streamer::Heuristic.new(streamer, "somefile.bin")
    assert_nothing_raised do
      ((64 * 1024) + 2).times { heuristic << "é" }
      heuristic.close
    end
  end
end
