# frozen_string_literal: true

# Require all the sub-components except myself
module ZipTricks
  autoload :RackBody, File.dirname(__FILE__) + "/zip_tricks/rack_body.rb"
  autoload :RailsStreaming, File.dirname(__FILE__) + "/zip_tricks/rails_streaming.rb"
  autoload :ZipWriter, File.dirname(__FILE__) + "/zip_tricks/zip_writer.rb"
  autoload :RemoteIO, File.dirname(__FILE__) + "/zip_tricks/remote_io.rb"
  autoload :NullWriter, File.dirname(__FILE__) + "/zip_tricks/null_writer.rb"
  autoload :OutputEnumerator, File.dirname(__FILE__) + "/zip_tricks/output_enumerator.rb"
  autoload :BlockDeflate, File.dirname(__FILE__) + "/zip_tricks/block_deflate.rb"
  autoload :WriteAndTell, File.dirname(__FILE__) + "/zip_tricks/write_and_tell.rb"
  autoload :RemoteUncap, File.dirname(__FILE__) + "/zip_tricks/remote_uncap.rb"
  autoload :FileReader, File.dirname(__FILE__) + "/zip_tricks/file_reader.rb"
  autoload :UniquifyFilename, File.dirname(__FILE__) + "/zip_tricks/uniquify_filename.rb"
  autoload :SizeEstimator, File.dirname(__FILE__) + "/zip_tricks/size_estimator.rb"
  autoload :Streamer, File.dirname(__FILE__) + "/zip_tricks/streamer.rb"
  autoload :PathSet, File.dirname(__FILE__) + "/zip_tricks/path_set.rb"
  autoload :StreamCRC32, File.dirname(__FILE__) + "/zip_tricks/stream_crc32.rb"
  autoload :BlockWrite, File.dirname(__FILE__) + "/zip_tricks/block_write.rb"
  autoload :WriteBuffer, File.dirname(__FILE__) + "/zip_tricks/write_buffer.rb"
  autoload :WriteShovel, File.dirname(__FILE__) + "/zip_tricks/write_shovel.rb"
end
