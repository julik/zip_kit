# zip_kit

Allows streaming, non-rewinding ZIP file output from Ruby.

`zip_kit` is a successor to and continuation of [zip_tricks](https://github.com/WeTransfer/zip_tricks), which
was inspired by [zipline](https://github.com/fringd/zipline).

Allows you to write a ZIP archive out to a `File`, `Socket`, `String` or `Array` without having to rewind it at any
point. Usable for creating very large ZIP archives for immediate sending out to clients, or for writing
large ZIP archives without memory inflation.

The original gem (zip_tricks) handled all the zipping needs (millions of ZIP files generated per day),
for a large file transfer service, so we are pretty confident it is widely compatible with a large number
of unarchiving end-user applications and is well tested.

## Requirements

Ruby 2.6+ syntax support is required, as well as a a working zlib (all available to jRuby as well).

## Diving in: send some large CSV reports from Rails

The easiest is to include the `ZipKit::RailsStreaming` module into your
controller. You will then have a `zip_kit_stream` method available which accepts a block:

```ruby
class ZipsController < ActionController::Base
  include ZipKit::RailsStreaming

  def download
    zip_kit_stream do |zip|
      zip.write_file('report1.csv') do |sink|
        CSV(sink) do |csv_write|
          csv_write << Person.column_names
          Person.all.find_each do |person|
            csv_write << person.attributes.values
          end
        end
      end
      zip.write_file('report2.csv') do |sink|
        ...
      end
    end
  end
end
```

The `write_file` method will use some heuristics to determine whether your output file would benefit
from compression, and pick the appropriate storage mode for the file accordingly.

If you want some more conveniences you can also use [zipline](https://github.com/fringd/zipline) which
will automatically process and stream attachments (Carrierwave, Shrine, ActiveStorage) and remote objects
via HTTP.

`RailsStreaming` will *not* use [ActionController::Live](https://api.rubyonrails.org/classes/ActionController/Live.html)
and the ZIP output will run in the same thread as your main request. Your testing flows (be it minitest or
RSpec) should work normally with controller actions returning ZIPs.

## Writing into other streaming destinations

Any object that accepts bytes via either `<<` or `write` methods can be a write destination. For example, here
is how to upload a sizeable ZIP to S3 - the SDK will happily chop your upload into multipart upload parts:

```ruby
bucket = Aws::S3::Bucket.new("mybucket")
obj = bucket.object("big.zip")
obj.upload_stream do |write_stream|
  ZipKit::Streamer.open(write_stream) do |zip|
    zip.write_file("large.csv") do |sink|
      CSV(sink) do |csv|
        csv << ["Line", "Item"]
        20_000.times do |n|
          csv << [n, "Item number #{n}"]
        end
      end
    end
  end
end
```

# Writing through an intermediary object

Any object that writes using either `<<` or `write` can write into a `sink`. For example, you can do streaming
output with [builder](https://github.com/jimweirich/builder#project-builder)

```ruby
zip.write_file('report1.csv') do |sink|
  builder = Builder::XmlMarkup.new(target: sink, indent: 2)
  builder.people do
    Person.all.find_each do |person|
      builder.person(name: person.name)
    end
  end
end
```

and this output will be compressed and output into the ZIP file on the fly. zip_kit composes with any
Ruby code that streams its output into a destination.

## Create a ZIP file without size estimation, compress on-the-fly during writes

Basic use case is compressing on the fly. Some data will be buffered by the Zlib deflater, but
memory inflation is going to be very constrained. Data will be written to destination at fairly regular
intervals. Deflate compression will work best for things like text files.

```ruby
out = my_tempfile # can also be a socket
ZipKit::Streamer.open(out) do |zip|
  zip.write_file('mov.mp4.txt') do |sink|
    File.open('mov.mp4', 'rb'){|source| IO.copy_stream(source, sink) }
  end
  zip.write_file('long-novel.txt') do |sink|
    File.open('novel.txt', 'rb'){|source| IO.copy_stream(source, sink) }
  end
end
```
Unfortunately with this approach it is impossible to compute the size of the ZIP file being output,
since you do not know how large the compressed data segments are going to be.

## Send a ZIP from a Rack response

zip_kit provides an `OutputEnumerator` object which will yield the binary chunks piece
by piece, and apply some amount of buffering as well. Make sure to also wrap your `OutputEnumerator` in a chunker
by calling `#to_chunked` on it. Return it to your webserver and you will have your ZIP streamed!
The block that you give to the `OutputEnumerator` receive the {ZipKit::Streamer} object and will only
start executing once your response body starts getting iterated over - when actually sending
the response to the client (unless you are using a buffering Rack webserver, such as Webrick).

```ruby
body = ZipKit::OutputEnumerator.new do | zip |
  zip.write_file('mov.mp4') do |sink|
    File.open('mov.mp4', 'rb'){|source| IO.copy_stream(source, sink) }
  end
  zip.write_file('long-novel.txt') do |sink|
    File.open('novel.txt', 'rb'){|source| IO.copy_stream(source, sink) }
  end
end

headers, streaming_body = body.to_rack_response_headers_and_body(env)
[200, headers, streaming_body]
```

## Send a ZIP file of known size, with correct headers

Use the `SizeEstimator` to compute the correct size of the resulting archive.

```ruby
# Precompute the Content-Length ahead of time
bytesize = ZipKit::SizeEstimator.estimate do |z|
 z.add_stored_entry(filename: 'myfile1.bin', size: 9090821)
 z.add_stored_entry(filename: 'myfile2.bin', size: 458678)
end

# Prepare the response body. The block will only be called when the response starts to be written.
zip_body = ZipKit::OutputEnumerator.new do | zip |
  zip.add_stored_entry(filename: "myfile1.bin", size: 9090821, crc32: 12485)
  zip << read_file('myfile1.bin')
  zip.add_stored_entry(filename: "myfile2.bin", size: 458678, crc32: 89568)
  zip << read_file('myfile2.bin')
end

headers, streaming_body = body.to_rack_response_headers_and_body(env, content_length: bytesize)
[200, headers, streaming_body]
```

## Writing ZIP files using the Streamer bypass

You do not have to "feed" all the contents of the files you put in the archive through the Streamer object.
If the write destination for your use case is a `Socket` (say, you are writing using Rack hijack) and you know
the metadata of the file upfront (the CRC32 of the uncompressed file and the sizes), you can write directly
to that socket using some accelerated writing technique, and only use the Streamer to write out the ZIP metadata.

```ruby
# io has to be an object that supports #<< or #write()
ZipKit::Streamer.open(io) do | zip |
  # raw_file is written "as is" (STORED mode).
  # Write the local file header first..
  zip.add_stored_entry(filename: "first-file.bin", size: raw_file.size, crc32: raw_file_crc32)

  # Adjust the ZIP offsets within the Streamer
  zip.simulate_write(my_temp_file.size)

  # ...and then send the actual file contents bypassing the Streamer interface
  io.sendfile(my_temp_file)
end
```

## Other usage examples

Check out the `examples/` directory at the root of the project. This will give you a good idea
of various use cases the library supports.

### Computing the CRC32 value of a large file

`BlockCRC32` computes the CRC32 checksum of an IO in a streaming fashion.
It is slightly more convenient for the purpose than using the raw Zlib library functions.

```ruby
crc = ZipKit::StreamCRC32.new
crc << next_chunk_of_data
...

crc.to_i # Returns the actual CRC32 value computed so far
...
# Append a known CRC32 value that has been computed previosuly
crc.append(precomputed_crc32, size_of_the_blob_computed_from)
```

You can also compute the CRC32 for an entire IO object if it responds to `#eof?`:

```ruby
crc = ZipKit::StreamCRC32.from_io(file) # Returns an Integer
```

### Reading ZIP files

The library contains a reader module, play with it to see what is possible. It is not a complete ZIP reader
but it was designed for a specific purpose (highly-parallel unpacking of remotely stored ZIP files), and
as such it performs it's function quite well. Please beware of the security implications of using ZIP readers
that have not been formally verified (ours hasn't been).

## Contributing to zip_kit

* Check out the latest `main` to make sure the feature hasn't been implemented or the bug hasn't been fixed yet.
* Check out the issue tracker to make sure someone already hasn't requested it and/or contributed it.
* Fork the project.
* Start a feature/bugfix branch.
* Commit and push until you are happy with your contribution.
* Make sure to add tests for it. This is important so I don't break it in a future version unintentionally.
* Please try not to mess with the Rakefile, version, or history. If you want to have your own version, or is otherwise necessary, that is fine, but please isolate to its own commit so I can cherry-pick around it.

## Copyright

Copyright (c) 2024 Julik Tarkhanov. See LICENSE.txt for further details.
