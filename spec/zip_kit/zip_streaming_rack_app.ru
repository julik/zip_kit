require_relative "../../lib/zip_kit"
require "action_controller"

# Serve the test directory, where we are going to emit the ZIP file into.
# Rack::File provides built-in support for Range: HTTP requests.
zip_serving_app = ->(env) {
  rng = Random.new(42)
  enum = ZipKit::OutputEnumerator.new do |zip|
    40.times do |n|
      zip.write_file("file_#{n}.bin") do |sink|
        sink << rng.bytes(1024 * 2)
      end
    end
  end

  [200, enum.streaming_http_headers, enum]
}

class ZipController < ActionController::Base
  include ZipKit::RailsStreaming
  def download
    zip_kit_stream do |z|
      rng = Random.new(42)
      z.write_file("some.bin") do |io|
        1024.times { io << rng.bytes(1024 * 64) }
      end
    end
  end

  def download_with_forced_chunking
    zip_kit_stream(use_chunked_transfer_encoding: true) do |z|
      rng = Random.new(42)
      z.write_file("some.bin") do |io|
        1024.times { io << rng.bytes(1024 * 64) }
      end
    end
  end
end

class ZipControllerWithLive < ZipController
  include ActionController::Live
end

map "/rack-app" do
  run zip_serving_app
end

map "/rails-controller-implicit-chunking" do
  run ZipController.action(:download)
end

map "/rails-controller-explicit-chunking" do
  run ZipController.action(:download_with_forced_chunking)
end

map "/rails-controller-with-live-implicit-chunking" do
  run ZipControllerWithLive.action(:download)
end

map "/rails-controller-with-live-explicit-chunking" do
  run ZipControllerWithLive.action(:download_with_forced_chunking)
end
