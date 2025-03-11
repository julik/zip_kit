require_relative "../spec_helper"

describe "ZipKit::ZlibCleanup" do
  it "does not raise when cleaning up the deflater which is in any step" do
    cleaner = Object.new
    class << cleaner
      include ZipKit::ZlibCleanup
    end

    steps = [
      ->(flate) { flate.deflate(Random.bytes(14)) },
      ->(flate) { flate.deflate(Random.bytes(14)) },
      ->(flate) { flate.deflate(Random.bytes(14)) },
      ->(flate) { flate.deflate(Random.bytes(14)) },
      ->(flate) { flate.finish until flate.finished? },
      ->(flate) { flate.close }
    ]

    safe_close = cleaner.method(:safely_dispose_of_incomplete_deflater).to_proc
    steps.length.times do |at_offset|
      steps_with_failure = steps.dup
      steps_with_failure.insert(at_offset, safe_close)

      deflater = ::Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -::Zlib::MAX_WBITS)
      steps_with_failure.each do |step_proc|
        step_proc.call(deflater)
        break if step_proc == safe_close
      end
    end
  end
end
