require_relative "../../lib/zip_kit"

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
run zip_serving_app
