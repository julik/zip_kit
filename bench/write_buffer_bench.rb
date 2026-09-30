# Benchmarks ZipKit::WriteBuffer with lots of tiny writes (like the XML fragments
# a library such as caxlsx produces) and with large writes, comparing it to the
# previous implementations of WriteBuffer.
#
#   bundle exec ruby bench/write_buffer_bench.rb
require "bundler"
Bundler.setup

require "benchmark"
require "benchmark/ips"
require_relative "../lib/zip_kit"

# Initialization and flushing as in zip_kit 6.3.x. These are not subclasses of ZipKit::WriteBuffer
# on purpose: with Ruby 3.4, instances of a subclass can have a different object shape, which
# can make the instance variable caches of methods they share with ZipKit::WriteBuffer miss.
module WriteBuffer63x
  def initialize(writable, buffer_size)
    @buf = ("\0".b * (buffer_size * 2)).clear
    @buffer_size = buffer_size
    @writable = writable
  end

  def flush
    unless @buf.empty?
      @writable << @buf
      @buf.clear
    end
    self
  end
end

# WriteBuffer#<< as of zip_kit 6.3.2
class WriteBuffer632
  include WriteBuffer63x

  def <<(data)
    if data.bytesize >= @buffer_size
      flush unless @buf.empty?
      @writable << data
    else
      @buf << data
      flush if @buf.bytesize >= @buffer_size
    end
    self
  end
end

# WriteBuffer#<< as of zip_kit 6.3.3/6.3.4, which copies every string with String#b
class WriteBuffer634
  include WriteBuffer63x

  def <<(string)
    if string.bytesize >= @buffer_size
      flush
      @writable << string.b
    else
      @buf << string.b
      flush if @buf.bytesize >= @buffer_size
    end
    self
  end
end

# The simplest possible buffer, which does not deal with encodings or large writes
class NaiveBuffer
  def initialize(io, buffer_size)
    @io = io
    @buffer_size = buffer_size
    @buf = "".b
  end

  def <<(fragment)
    @buf << fragment
    flush if @buf.bytesize >= @buffer_size
    self
  end

  def flush
    return if @buf.empty?
    @io << @buf
    @buf.clear
  end
end

BUFFER_SIZE = 64 * 1024
IMPLEMENTATIONS = {
  "WriteBuffer" => ZipKit::WriteBuffer,
  "WriteBuffer (6.3.2)" => WriteBuffer632,
  "WriteBuffer (6.3.4, String#b)" => WriteBuffer634,
  "Naive String buffer" => NaiveBuffer
}

# Fragments like the ones produced by caxlsx when writing out a worksheet: mostly frozen
# literals and short dynamic strings (UTF-8 or US-ASCII), mostly ASCII-only.
fragments = []
20_000.times do |row|
  fragments << "<row r=\"" << (row + 1).to_s << "\">"
  6.times do |col|
    fragments << "<c r=\"" << "#{("A".ord + col).chr}#{row + 1}" << "\" s=\"" << "1" << "\""
    fragments << ((col == 3) ? " t=\"inlineStr\"><is><t>Grüße, #{row}</t></is>" : "><v>#{row * col}</v>")
    fragments << "</c>"
  end
  fragments << "</row>"
end
n_bytes = fragments.sum(&:bytesize)

puts RUBY_DESCRIPTION
puts "#{fragments.length} tiny writes (#{n_bytes} bytes, #{(n_bytes.to_f / fragments.length).round(1)} bytes per write on average)"

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)
  IMPLEMENTATIONS.each do |name, buffer_class|
    x.report("#{name}, tiny writes into CRC32") do
      buf = buffer_class.new(ZipKit::StreamCRC32.new, BUFFER_SIZE)
      fragments.each { |fragment| buf << fragment }
      buf.flush
    end
  end
  x.compare!
end

Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)
  IMPLEMENTATIONS.each do |name, buffer_class|
    x.report("#{name}, tiny writes into write_deflated_file") do
      ZipKit::Streamer.open(ZipKit::NullWriter) do |zip|
        zip.write_deflated_file("sheet.xml") do |sink|
          buf = buffer_class.new(sink, BUFFER_SIZE)
          fragments.each { |fragment| buf << fragment }
          buf.flush
        end
      end
    end
  end
  x.report("No buffer, tiny writes into write_deflated_file") do
    ZipKit::Streamer.open(ZipKit::NullWriter) do |zip|
      zip.write_deflated_file("sheet.xml") do |sink|
        fragments.each { |fragment| sink << fragment }
      end
    end
  end
  x.compare!
end

large_chunk = Random.new(42).bytes(1024 * 1024)
Benchmark.ips do |x|
  x.config(time: 5, warmup: 2)
  IMPLEMENTATIONS.each do |name, buffer_class|
    x.report("#{name}, 64 writes of 1MB into CRC32") do
      buf = buffer_class.new(ZipKit::StreamCRC32.new, BUFFER_SIZE)
      64.times { buf << large_chunk }
      buf.flush
    end
  end
  x.compare!
end
