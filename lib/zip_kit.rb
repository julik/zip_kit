# frozen_string_literal: true

require_relative "zip_kit/version"
require "zlib"

module ZipKit
  autoload :OutputEnumerator, File.dirname(__FILE__) + "/zip_kit/rack_body.rb"
  autoload :RailsStreaming, File.dirname(__FILE__) + "/zip_kit/rails_streaming.rb"
  autoload :ZipWriter, File.dirname(__FILE__) + "/zip_kit/zip_writer.rb"
  autoload :RemoteIO, File.dirname(__FILE__) + "/zip_kit/remote_io.rb"
  autoload :NullWriter, File.dirname(__FILE__) + "/zip_kit/null_writer.rb"
  autoload :OutputEnumerator, File.dirname(__FILE__) + "/zip_kit/output_enumerator.rb"
  autoload :BlockDeflate, File.dirname(__FILE__) + "/zip_kit/block_deflate.rb"
  autoload :WriteAndTell, File.dirname(__FILE__) + "/zip_kit/write_and_tell.rb"
  autoload :RemoteUncap, File.dirname(__FILE__) + "/zip_kit/remote_uncap.rb"
  autoload :FileReader, File.dirname(__FILE__) + "/zip_kit/file_reader.rb"
  autoload :UniquifyFilename, File.dirname(__FILE__) + "/zip_kit/uniquify_filename.rb"
  autoload :SizeEstimator, File.dirname(__FILE__) + "/zip_kit/size_estimator.rb"
  autoload :Streamer, File.dirname(__FILE__) + "/zip_kit/streamer.rb"
  autoload :PathSet, File.dirname(__FILE__) + "/zip_kit/path_set.rb"
  autoload :StreamCRC32, File.dirname(__FILE__) + "/zip_kit/stream_crc32.rb"
  autoload :BlockWrite, File.dirname(__FILE__) + "/zip_kit/block_write.rb"
  autoload :WriteBuffer, File.dirname(__FILE__) + "/zip_kit/write_buffer.rb"
  autoload :WriteShovel, File.dirname(__FILE__) + "/zip_kit/write_shovel.rb"
  autoload :RackChunkedBody, File.dirname(__FILE__) + "/zip_kit/rack_chunked_body.rb"
  autoload :RackTempfileBody, File.dirname(__FILE__) + "/zip_kit/rack_tempfile_body.rb"
  autoload :ZlibCleanup, File.dirname(__FILE__) + "/zip_kit/zlib_cleanup.rb"

  require_relative "zip_kit/railtie" if defined?(::Rails)
end
