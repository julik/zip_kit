require "test_helper"
require "net/http"

class ZipStreamingViaRackTest < TestCase
  def setup
    super
    @server_addr = PumaServer.boot(File.expand_path("zip_streaming_rack_app.ru", __dir__))
  end

  paths = %w[
    rack-app
    rails-controller-implicit-chunking
    rails-controller-explicit-chunking
    rails-controller-with-live-implicit-chunking
    rails-controller-with-live-explicit-chunking
    sinatra-app
  ]
  paths.each do |path|
    test "serves a ZIP correctly via /#{path}" do
      url = "http://#{@server_addr}/#{path}"
      uri = URI.parse(url)

      http = Net::HTTP.start(uri.hostname, uri.port)
      request = Net::HTTP::Get.new(url)
      response = http.request(request)

      assert_equal 183308, response.body.bytesize

      assert_equal "application/zip", response.header["Content-Type"]
      assert_nil response.header["Content-Length"]
      assert_equal "chunked", response.header["Transfer-Encoding"] # Puma should auto-add it
    end
  end
end
