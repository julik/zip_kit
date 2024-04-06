require "bundler"
Bundler.setup

require "benchmark"
require "benchmark/ips"
require_relative "../lib/zip_kit"

n_bytes = 5 * 1024 * 1024
r = Random.new
bytes = (0...n_bytes).map { r.bytes(1) }
buffer_sizes = [
  1,
  256,
  512,
  1024,
  8 * 1024,
  16 * 1024,
  32 * 1024,
  64 * 1024,
  128 * 1024,
  256 * 1024,
  512 * 1024,
  1024 * 1024,
  2 * 1024 * 1024
]

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)
  buffer_sizes.each do |buf_size|
    x.report "Single-byte <<-writes of #{n_bytes} using a #{buf_size} byte buffer" do
      crc = ZipKit::StreamCRC32.new
      buf = ZipKit::WriteBuffer.new(crc, buf_size)
      bytes.each { |b| buf << b }
      crc.to_i
    end
  end
  x.compare!
end

__END__

Comparison:
Single-byte <<-writes of 5242880 using a 262144 byte buffer:        1.0 i/s
Single-byte <<-writes of 5242880 using a 65536 byte buffer:        0.9 i/s - 1.00x  slower
Single-byte <<-writes of 5242880 using a 32768 byte buffer:        0.9 i/s - 1.00x  slower
Single-byte <<-writes of 5242880 using a 16384 byte buffer:        0.9 i/s - 1.01x  slower
Single-byte <<-writes of 5242880 using a 524288 byte buffer:        0.9 i/s - 1.01x  slower
Single-byte <<-writes of 5242880 using a 8192 byte buffer:        0.9 i/s - 1.01x  slower
Single-byte <<-writes of 5242880 using a 256 byte buffer:        0.9 i/s - 1.01x  slower
Single-byte <<-writes of 5242880 using a 131072 byte buffer:        0.9 i/s - 1.01x  slower
Single-byte <<-writes of 5242880 using a 1024 byte buffer:        0.9 i/s - 1.02x  slower
Single-byte <<-writes of 5242880 using a 512 byte buffer:        0.9 i/s - 1.02x  slower
Single-byte <<-writes of 5242880 using a 2097152 byte buffer:        0.9 i/s - 1.05x  slower
Single-byte <<-writes of 5242880 using a 1048576 byte buffer:        0.9 i/s - 1.06x  slower
Single-byte <<-writes of 5242880 using a 1 byte buffer:        0.8 i/s - 1.25x  slower
