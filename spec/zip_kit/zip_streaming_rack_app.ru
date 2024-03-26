require_relative "../../lib/zip_kit"
require "action_controller"
require "sinatra/base"

# Serve the test directory, where we are going to emit the ZIP file into.
# Rack::File provides built-in support for Range: HTTP requests.
zip_serving_app = ->(env) {
  enum = ZipKit::OutputEnumerator.new do |z|
    z.write_file("tolstoy.txt") do |io|
      File.open(File.dirname(__FILE__) + "/war-and-peace.txt", "r") do |f|
        IO.copy_stream(f, io)
      end
    end
  end

  [200, enum.streaming_http_headers, enum]
}

class ZipController < ActionController::Base
  include ZipKit::RailsStreaming
  def download
    zip_kit_stream do |z|
      z.write_file("tolstoy.txt") do |io|
        File.open(File.dirname(__FILE__) + "/war-and-peace.txt", "r") do |f|
          IO.copy_stream(f, io)
        end
      end
    end
  end

  def download_with_forced_chunking
    zip_kit_stream(use_chunked_transfer_encoding: true) do |z|
      z.write_file("tolstoy.txt") do |io|
        File.open(File.dirname(__FILE__) + "/war-and-peace.txt", "r") do |f|
          IO.copy_stream(f, io)
        end
      end
    end
  end
end

class ZipControllerWithLive < ZipController
  include ActionController::Live
end

class SinatraApp < Sinatra::Base
  get "/" do
    content_type :zip
    stream do |out|
      ZipKit::Streamer.open(out) do |z|
        z.write_file("tolstoy.txt") do |io|
          File.open(File.dirname(__FILE__) + "/war-and-peace.txt", "r") do |f|
            IO.copy_stream(f, io)
          end
        end
      end
    end
  end
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

map "/sinatra-app" do
  run SinatraApp
end
