require "sinatra/base"

class SinatraApp < Sinatra::Base
  get "/" do
    content_type :zip
    stream do |out|
      ZipKit::Streamer.open(out) do |z|
        z.write_file(File.basename(__FILE__)) do |io|
          File.open(__FILE__, "r") do |f|
            IO.copy_stream(f, io)
          end
        end
      end
    end
  end
end
