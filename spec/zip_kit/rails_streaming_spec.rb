require "spec_helper"
require "action_controller"

describe ZipKit::RailsStreaming do
  class FakeZipGenerator
    def generate_once(streamer)
      # Only allow the call to be executed once, to ensure that we run
      # our ZIP generation block just once. This is to ensure Rack::ContentLength
      # does not run the generation twice
      raise "The ZIP has already been generated once" if @did_generate_zip
      streamer.write_file("hello.txt") do |f|
        f << "ßHello from Rails"
      end
      @did_generate_zip = true
    end

    def self.generate_reference
      StringIO.new.binmode.tap do |sio|
        ZipKit::Streamer.open(sio) do |streamer|
          new.generate_once(streamer)
        end
        sio.rewind
      end
    end
  end

  class FakeController < ActionController::Base
    # Make sure both Rack middlewares which are known to cause trouble
    # are used in this controller, so that we can ensure they get bypassed.
    # Use them in the same order Rails inserts them.
    middleware.use Rack::Sendfile
    middleware.use Rack::ETag
    middleware.use Rack::Deflater
    middleware.use Rack::ContentLength # This does not get injected by Rails
    middleware.use Rack::TempfileReaper

    include ZipKit::RailsStreaming
    def stream_zip
      generator = FakeZipGenerator.new
      zip_kit_stream(auto_rename_duplicate_filenames: true) do |z|
        generator.generate_once(z)
      end
    end

    def stream_zip_with_forced_chunking
      generator = FakeZipGenerator.new
      zip_kit_stream(auto_rename_duplicate_filenames: true, use_chunked_transfer_encoding: true) do |z|
        generator.generate_once(z)
      end
    end
  end

  it "degrades to a buffered response with HTTP/1.0 and produces a ZIP" do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.0",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new
    }
    status, headers, body = FakeController.action(:stream_zip).call(fake_rack_env)

    ref_output_io = FakeZipGenerator.generate_reference
    out = readback_iterable(body)
    expect(out.string).to eq(ref_output_io.string)
    expect { body.close }.not_to raise_error
    expect(status).to eq(200)
    expect_correct_headers!(headers)

    expect(headers["X-Accel-Buffering"]).to eq("no")
    expect(headers["Transfer-Encoding"]).to be_nil
    expect(headers["Content-Length"]).to be_kind_of(String)
    # All the other methods have been excercised by reading out the iterable body
  end

  it "uses Transfer-Encoding: chunked when requested" do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.1",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new
    }
    status, headers, body = FakeController.action(:stream_zip_with_forced_chunking).call(fake_rack_env)

    ref_output_io = FakeZipGenerator.generate_reference
    out = decode_chunked_encoding(readback_iterable(body))
    expect(out.string.b).to eq(ref_output_io.string.b)

    expect(status).to eq(200)
    expect_correct_headers!(headers)

    expect(headers["X-Accel-Buffering"]).to eq("no")
    expect(headers["Transfer-Encoding"]).to eq("chunked")
    expect(headers["Content-Length"]).to be_nil # Must be unset!
    expect(body).not_to respond_to(:to_path) # for Rack::Sendfile
  end

  def readback_iterable(iterable)
    StringIO.new.binmode.tap do |out|
      iterable.each { |chunk| out.write(chunk) }
      out.rewind
    end
  end

  def expect_correct_headers!(headers)
    expect(headers["Content-Type"]).to eq("application/zip")
    expect(headers["ETag"]).to be_nil # if the ETag middleware activates it will generate a weak ETag
    expect(headers["Last-Modified"]).to be_kind_of(String)
    expect(headers["Content-Encoding"]).to eq("identity")
    expect(headers["Cache-Control"]).to include("private")
  end
end
