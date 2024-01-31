require 'spec_helper'
require 'action_controller'

describe ZipTricks::RailsStreaming do
  module FakeZipGenerator
    def self.call(streamer)
      streamer.write_deflated_file('hello.txt') do |f|
        f << 'ßHello from Rails'
      end
    end

    def self.generate_reference
      StringIO.new.binmode.tap do |sio|
        ZipTricks::Streamer.open(sio) do |streamer|
          call(streamer)
        end
        sio.rewind
      end
    end
  end

  class FakeController < ActionController::Base
    # Make sure both Rack middlewares which are known to cause trouble
    # are used in this controller, so that we can ensure they get bypassed
    middleware.use Rack::ETag
    middleware.use Rack::ContentLength

    include ZipTricks::RailsStreaming
    def stream_zip
      zip_tricks_stream(auto_rename_duplicate_filenames: true) do |z|
        FakeZipGenerator.call(z)
      end
    end
  end

  it 'degrades to a buffered response with HTTP/1.0 and produces a ZIP' do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.0",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new,
    }
    status, headers, body = FakeController.action(:stream_zip).call(fake_rack_env)

    ref_output_io = FakeZipGenerator.generate_reference
    out = readback_iterable(body)
    expect(out.string).to eq(ref_output_io.string)

    expect(status).to eq(200)
    expect(headers['Content-Type']).to eq('application/zip')
    expect(headers['ETag']).to be_nil # if the ETag middleware activates it will generate a weak ETag
    expect(headers['Last-Modified']).to be_kind_of(String)
    expect(headers['X-Accel-Buffering']).to be_nil # Response gets buffered
    expect(headers['Transfer-Encoding']).to be_nil
    # ... and Content-Length may or may not be present
  end

  it 'uses Transfer-Encoding: chunked with HTTP/1.1 and produces a chunked response' do
    fake_rack_env = {
      "HTTP_VERSION" => "HTTP/1.1",
      "REQUEST_METHOD" => "GET",
      "SCRIPT_NAME" => "",
      "PATH_INFO" => "/download",
      "QUERY_STRING" => "",
      "SERVER_NAME" => "host.example",
      "rack.input" => StringIO.new,
    }
    status, headers, body = FakeController.action(:stream_zip).call(fake_rack_env)

    ref_output_io = FakeZipGenerator.generate_reference
    out = decode_chunked_encoding(readback_iterable(body))
    expect(out.string).to eq(ref_output_io.string)

    expect(status).to eq(200)
    expect(headers['Content-Type']).to eq('application/zip')
    expect(headers['ETag']).to be_nil # if the ETag middleware activates it will generate a weak ETag
    expect(headers['Last-Modified']).to be_kind_of(String)
    expect(headers['X-Accel-Buffering']).to eq('no')
    expect(headers['Transfer-Encoding']).to eq('chunked')
    expect(headers['Content-Length']).to be_nil # Must be unset!
  end

  def decode_chunked_encoding(io)
    # Lifted from Net::HTTP mostly
    StringIO.new.binmode.tap do |dest|
      begin
        loop do
          line = io.readline
          hexlen = line.slice(/[0-9a-fA-F]+/)
          len = hexlen.hex
          break if len == 0 # Terminator (hex 0 followed by \r\n)

          dest.write(io.read(len))
          io.read(2)   # \r\n
        end
      rescue EOFError
        # nothing
      ensure
        dest.rewind
      end
    end
  end

  def readback_iterable(iterable)
    StringIO.new.binmode.tap do |out|
      iterable.each { |chunk| out.write(chunk) }
      out.rewind
    end
  end
end
