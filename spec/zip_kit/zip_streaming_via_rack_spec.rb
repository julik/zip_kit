require "spec_helper"
require "net/http"

describe "Streaming using OutputEnumerator and Rack" do
  before :all do
    rack_app = File.expand_path(__dir__ + "/zip_streaming_rack_app.ru")
    # find a free tcp port
    tcpserver = TCPServer.new("127.0.0.1", 0)
    port = tcpserver.addr[1]
    addr = tcpserver.addr[3]
    tcpserver.close
    @server_addr = "#{addr}:#{port}"
    command = %W[bundle exec puma --bind tcp://#{@server_addr} #{rack_app}]
    server = IO.popen(command, "r")
    @server_pid = server.pid
    # ensure server was sarted
    expect(@server_pid).not_to be_nil
    # wait for server to boot
    expect { Timeout.timeout(10) { nil until server.gets =~ /Ctrl-C/ } }.not_to raise_error
  end

  after :all do
    next if @server_pid.nil?
    begin
      Process.kill("TERM", @server_pid)
    rescue Errno::ESRCH
    end
    begin
      Process.wait(@server_pid)
    rescue Errno::ECHILD
    end
  end

  it "serves a ZIP correctly" do
    url = "http://#{@server_addr}/temp.zip"
    uri = URI.parse(url)

    http = Net::HTTP.start(uri.hostname, uri.port)
    request = Net::HTTP::Get.new(url)
    response = http.request(request)

    expect(response.header["Transfer-Encoding"]).to eq("chunked") # Puma should auto-add it
    expect(response.header["Content-Length"]).to be_nil

    expect(response.body.bytesize).to eq(87228)
  end
end
