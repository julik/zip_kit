require "socket"
require "timeout"

# Boots a Puma serving a rackup file, once per test run, and stops it when the run ends
module PumaServer
  @addrs = {}

  # Returns the "host:port" the app is served at. Puma gets started in the `chdir` directory.
  def self.boot(rack_app_path, chdir: Dir.pwd)
    @addrs[rack_app_path] ||= begin
      # find a free tcp port
      tcpserver = TCPServer.new("127.0.0.1", 0)
      port = tcpserver.addr[1]
      addr = tcpserver.addr[3]
      tcpserver.close
      server_addr = "#{addr}:#{port}"
      server = IO.popen(%W[bundle exec puma --bind tcp://#{server_addr} #{rack_app_path}], "r", chdir: chdir)
      server_pid = server.pid
      raise "puma did not start for #{rack_app_path}" if server_pid.nil?
      Minitest.after_run do
        begin
          Process.kill("TERM", server_pid)
        rescue Errno::ESRCH
        end
        begin
          Process.wait(server_pid)
        rescue Errno::ECHILD
        end
        server.close
      end
      # wait for server to boot
      Timeout.timeout(10) { nil until server.gets =~ /Ctrl-C/ }
      server_addr
    end
  end
end
