# typed: strong
module ZipKit
  VERSION = T.let("6.1.0", T.untyped)

  # A ZIP archive contains a flat list of entries. These entries can implicitly
  # create directories when the archive is expanded. For example, an entry with
  # the filename of "some folder/file.docx" will make the unarchiving application
  # create a directory called "some folder" automatically, and then deposit the
  # file "file.docx" in that directory. These "implicit" directories can be
  # arbitrarily nested, and create a tree structure of directories. That structure
  # however is implicit as the archive contains a flat list.
  # 
  # This creates opportunities for conflicts. For example, imagine the following
  # structure:
  # 
  # * `something/` - specifies an empty directory with the name "something"
  # * `something` - specifies a file, creates a conflict
  # 
  # This can be prevented with filename uniqueness checks. It does get funkier however
  # as the rabbit hole goes down:
  # 
  # * `dir/subdir/another_subdir/yet_another_subdir/file.bin` - declares a file and directories
  # * `dir/subdir/another_subdir/yet_another_subdir` - declares a file at one of the levels, creates a conflict
  # 
  # The results of this ZIP structure aren't very easy to predict as they depend on the
  # application that opens the archive. For example, BOMArchiveHelper on macOS will expand files
  # as they are declared in the ZIP, but once a conflict occurs it will fail with "error -21". It
  # is not very transparent to the user why unarchiving fails, and it has to - and can reliably - only
  # be prevented when the archive gets created.
  # 
  # Unfortunately that conflicts with another "magical" feature of ZipKit which automatically
  # "fixes" duplicate filenames - filenames (paths) which have already been added to the archive.
  # This fix is performed by appending (1), then (2) and so forth to the filename so that the
  # conflict is avoided. This is not possible to apply to directories, because when one of the
  # path components is reused in multiple filenames it means those entities should end up in
  # the same directory (subdirectory) once the archive is opened.
  # 
  # The `PathSet` keeps track of entries as they get added using 2 Sets (cheap presence checks),
  # one for directories and one for files. It will raise a `Conflict` exception if there are
  # files clobbering one another, or in case files collide with directories.
  class PathSet
    sig { void }
    def initialize; end

    # Adds a directory path to the set of known paths, including
    # all the directories that contain it. So, calling
    #    add_directory_path("dir/dir2/dir3")
    # will add "dir", "dir/dir2", "dir/dir2/dir3".
    # 
    # _@param_ `path` — the path to the directory to add
    sig { params(path: String).void }
    def add_directory_path(path); end

    # Adds a file path to the set of known paths, including
    # all the directories that contain it. Once a file has been added,
    # it is no longer possible to add a directory having the same path
    # as this would cause conflict.
    # 
    # The operation also adds all the containing directories for the file, so
    #    add_file_path("dir/dir2/file.doc")
    # will add "dir" and "dir/dir2" as directories, "dir/dir2/dir3".
    # 
    # _@param_ `file_path` — the path to the directory to add
    sig { params(file_path: String).void }
    def add_file_path(file_path); end

    # Tells whether a specific full path is already known to the PathSet.
    # Can be a path for a directory or for a file.
    # 
    # _@param_ `path_in_archive` — the path to check for inclusion
    sig { params(path_in_archive: String).returns(T::Boolean) }
    def include?(path_in_archive); end

    # Clears the contained sets
    sig { void }
    def clear; end

    # sord omit - no YARD type given for "path_in_archive", using untyped
    # Adds the directory or file path to the path set
    sig { params(path_in_archive: T.untyped).void }
    def add_directory_or_file_path(path_in_archive); end

    # sord omit - no YARD type given for "path", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(path: T.untyped).returns(T.untyped) }
    def non_empty_path_components(path); end

    # sord omit - no YARD type given for "path", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(path: T.untyped).returns(T.untyped) }
    def path_and_ancestors(path); end

    class Conflict < StandardError
    end

    class FileClobbersDirectory < ZipKit::PathSet::Conflict
    end

    class DirectoryClobbersFile < ZipKit::PathSet::Conflict
    end
  end

  # Is used to write streamed ZIP archives into the provided IO-ish object.
  # The output IO is never going to be rewound or seeked, so the output
  # of this object can be coupled directly to, say, a Rack output. The
  # output can also be a String, Array or anything that responds to `<<`.
  # 
  # Allows for splicing raw files (for "stored" entries without compression)
  # and splicing of deflated files (for "deflated" storage mode).
  # 
  # For stored entries, you need to know the CRC32 (as a uint) and the filesize upfront,
  # before the writing of the entry body starts.
  # 
  # Any object that responds to `<<` can be used as the Streamer target - you can use
  # a String, an Array, a Socket or a File, at your leisure.
  # 
  # ## Using the Streamer with runtime compression
  # 
  # You can use the Streamer with data descriptors (the CRC32 and the sizes will be
  # written after the file data). This allows non-rewinding on-the-fly compression.
  # The streamer will pick the optimum compression method ("stored" or "deflated")
  # depending on the nature of the byte stream you send into it (by using a small buffer).
  # If you are compressing large files, the Deflater object that the Streamer controls
  # will be regularly flushed to prevent memory inflation.
  # 
  #     ZipKit::Streamer.open(file_socket_or_string) do |zip|
  #       zip.write_file('mov.mp4') do |sink|
  #         File.open('mov.mp4', 'rb'){|source| IO.copy_stream(source, sink) }
  #       end
  #       zip.write_file('long-novel.txt') do |sink|
  #         File.open('novel.txt', 'rb'){|source| IO.copy_stream(source, sink) }
  #       end
  #     end
  # 
  # The central directory will be written automatically at the end of the block.
  # 
  # ## Using the Streamer with entries of known size and having a known CRC32 checksum
  # 
  # Streamer allows "IO splicing" - in this mode it will only control the metadata output,
  # but you can write the data to the socket/file outside of the Streamer. For example, when
  # using the sendfile gem:
  # 
  #     ZipKit::Streamer.open(socket) do | zip |
  #       zip.add_stored_entry(filename: "myfile1.bin", size: 9090821, crc32: 12485)
  #       socket.sendfile(tempfile1)
  #       zip.simulate_write(tempfile1.size)
  # 
  #       zip.add_stored_entry(filename: "myfile2.bin", size: 458678, crc32: 89568)
  #       socket.sendfile(tempfile2)
  #       zip.simulate_write(tempfile2.size)
  #     end
  # 
  # Note that you need to use `simulate_write` in this case. This needs to happen since Streamer
  # writes absolute offsets into the ZIP (local file header offsets and the like),
  # and it relies on the output object to tell it how many bytes have been written
  # so far. When using `sendfile` the Ruby write methods get bypassed entirely, and the
  # offsets in the IO will not be updated - which will result in an invalid ZIP.
  # 
  # 
  # ## On-the-fly deflate -using the Streamer with async/suspended writes and data descriptors
  # 
  # If you are unable to use the block versions of `write_deflated_file` and `write_stored_file`
  # there is an option to use a separate writer object. It gets returned from `write_deflated_file`
  # and `write_stored_file` if you do not provide them with a block, and will accept data writes.
  # Do note that you _must_ call `#close` on that object yourself:
  # 
  #     ZipKit::Streamer.open(socket) do | zip |
  #       w = zip.write_stored_file('mov.mp4')
  #       IO.copy_stream(source_io, w)
  #       w.close
  #     end
  # 
  # The central directory will be written automatically at the end of the `open` block. If you need
  # to manage the Streamer manually, or defer the central directory write until appropriate, use
  # the constructor instead and call `Streamer#close`:
  # 
  #     zip = ZipKit::Streamer.new(out_io)
  #     .....
  #     zip.close
  # 
  # Calling {Streamer#close} **will not** call `#close` on the underlying IO object.
  class Streamer
    include ZipKit::WriteShovel
    STORED = T.let(0, T.untyped)
    DEFLATED = T.let(8, T.untyped)
    EntryBodySizeMismatch = T.let(Class.new(StandardError), T.untyped)
    InvalidOutput = T.let(Class.new(ArgumentError), T.untyped)
    Overflow = T.let(Class.new(StandardError), T.untyped)
    UnknownMode = T.let(Class.new(StandardError), T.untyped)
    OffsetOutOfSync = T.let(Class.new(StandardError), T.untyped)

    # sord omit - no YARD return type given, using untyped
    # Creates a new Streamer on top of the given IO-ish object and yields it. Once the given block
    # returns, the Streamer will have it's `close` method called, which will write out the central
    # directory of the archive to the output.
    # 
    # _@param_ `stream` — the destination IO for the ZIP (should respond to `tell` and `<<`)
    # 
    # _@param_ `kwargs_for_new` — keyword arguments for #initialize
    sig { params(stream: IO, kwargs_for_new: T::Hash[T.untyped, T.untyped]).returns(T.untyped) }
    def self.open(stream, **kwargs_for_new); end

    # sord duck - #<< looks like a duck type, replacing with untyped
    # Creates a new Streamer on top of the given IO-ish object.
    # 
    # _@param_ `writable` — the destination IO for the ZIP. Anything that responds to `<<` can be used.
    # 
    # _@param_ `writer` — the object to be used as the writer. Defaults to an instance of ZipKit::ZipWriter, normally you won't need to override it
    # 
    # _@param_ `auto_rename_duplicate_filenames` — whether duplicate filenames, when encountered, should be suffixed with (1), (2) etc. Default value is `false` - if dupliate names are used an exception will be raised
    sig { params(writable: T.untyped, writer: ZipKit::ZipWriter, auto_rename_duplicate_filenames: T::Boolean).void }
    def initialize(writable, writer: create_writer, auto_rename_duplicate_filenames: false); end

    # Writes a part of a zip entry body (actual binary data of the entry) into the output stream.
    # 
    # _@param_ `binary_data` — a String in binary encoding
    # 
    # _@return_ — self
    sig { params(binary_data: String).returns(T.untyped) }
    def <<(binary_data); end

    # Advances the internal IO pointer to keep the offsets of the ZIP file in
    # check. Use this if you are going to use accelerated writes to the socket
    # (like the `sendfile()` call) after writing the headers, or if you
    # just need to figure out the size of the archive.
    # 
    # _@param_ `num_bytes` — how many bytes are going to be written bypassing the Streamer
    # 
    # _@return_ — position in the output stream / ZIP archive
    sig { params(num_bytes: Integer).returns(Integer) }
    def simulate_write(num_bytes); end

    # Writes out the local header for an entry (file in the ZIP) that is using
    # the deflated storage model (is compressed). Once this method is called,
    # the `<<` method has to be called to write the actual contents of the body.
    # 
    # Note that the deflated body that is going to be written into the output
    # has to be _precompressed_ (pre-deflated) before writing it into the
    # Streamer, because otherwise it is impossible to know it's size upfront.
    # 
    # _@param_ `filename` — the name of the file in the entry
    # 
    # _@param_ `modification_time` — the modification time of the file in the archive
    # 
    # _@param_ `compressed_size` — the size of the compressed entry that is going to be written into the archive
    # 
    # _@param_ `uncompressed_size` — the size of the entry when uncompressed, in bytes
    # 
    # _@param_ `crc32` — the CRC32 checksum of the entry when uncompressed
    # 
    # _@param_ `use_data_descriptor` — whether the entry body will be followed by a data descriptor
    # 
    # _@param_ `unix_permissions` — which UNIX permissions to set, normally the default should be used
    # 
    # _@return_ — the offset the output IO is at after writing the entry header
    sig do
      params(
        filename: String,
        modification_time: Time,
        compressed_size: Integer,
        uncompressed_size: Integer,
        crc32: Integer,
        unix_permissions: T.nilable(Integer),
        use_data_descriptor: T::Boolean
      ).returns(Integer)
    end
    def add_deflated_entry(filename:, modification_time: Time.now.utc, compressed_size: 0, uncompressed_size: 0, crc32: 0, unix_permissions: nil, use_data_descriptor: false); end

    # Writes out the local header for an entry (file in the ZIP) that is using
    # the stored storage model (is stored as-is).
    # Once this method is called, the `<<` method has to be called one or more
    # times to write the actual contents of the body.
    # 
    # _@param_ `filename` — the name of the file in the entry
    # 
    # _@param_ `modification_time` — the modification time of the file in the archive
    # 
    # _@param_ `size` — the size of the file when uncompressed, in bytes
    # 
    # _@param_ `crc32` — the CRC32 checksum of the entry when uncompressed
    # 
    # _@param_ `use_data_descriptor` — whether the entry body will be followed by a data descriptor. When in use
    # 
    # _@param_ `unix_permissions` — which UNIX permissions to set, normally the default should be used
    # 
    # _@return_ — the offset the output IO is at after writing the entry header
    sig do
      params(
        filename: String,
        modification_time: Time,
        size: Integer,
        crc32: Integer,
        unix_permissions: T.nilable(Integer),
        use_data_descriptor: T::Boolean
      ).returns(Integer)
    end
    def add_stored_entry(filename:, modification_time: Time.now.utc, size: 0, crc32: 0, unix_permissions: nil, use_data_descriptor: false); end

    # Adds an empty directory to the archive with a size of 0 and permissions of 755.
    # 
    # _@param_ `dirname` — the name of the directory in the archive
    # 
    # _@param_ `modification_time` — the modification time of the directory in the archive
    # 
    # _@param_ `unix_permissions` — which UNIX permissions to set, normally the default should be used
    # 
    # _@return_ — the offset the output IO is at after writing the entry header
    sig { params(dirname: String, modification_time: Time, unix_permissions: T.nilable(Integer)).returns(Integer) }
    def add_empty_directory(dirname:, modification_time: Time.now.utc, unix_permissions: nil); end

    # Opens the stream for a file stored in the archive, and yields a writer
    # for that file to the block.
    # The writer will buffer a small amount of data and see whether compression is
    # effective for the data being output. If compression turns out to work well -
    # for instance, if the output is mostly text - it is going to create a deflated
    # file inside the zip. If the compression benefits are negligible, it will
    # create a stored file inside the zip. It will delegate either to `write_deflated_file`
    # or to `write_stored_file`.
    # 
    # Using a block, the write will be terminated with a data descriptor outright.
    # 
    #     zip.write_file("foo.txt") do |sink|
    #       IO.copy_stream(source_file, sink)
    #     end
    # 
    # If deferred writes are desired (for example - to integrate with an API that
    # does not support blocks, or to work with non-blocking environments) the method
    # has to be called without a block. In that case it returns the sink instead,
    # permitting to write to it in a deferred fashion. When `close` is called on
    # the sink, any remanining compression output will be flushed and the data
    # descriptor is going to be written.
    # 
    # Note that even though it does not have to happen within the same call stack,
    # call sequencing still must be observed. It is therefore not possible to do
    # this:
    # 
    #     writer_for_file1 = zip.write_file("somefile.jpg")
    #     writer_for_file2 = zip.write_file("another.tif")
    #     writer_for_file1 << data
    #     writer_for_file2 << data
    # 
    # because it is likely to result in an invalid ZIP file structure later on.
    # So using this facility in async scenarios is certainly possible, but care
    # and attention is recommended.
    # 
    # _@param_ `filename` — the name of the file in the archive
    # 
    # _@param_ `modification_time` — the modification time of the file in the archive
    # 
    # _@param_ `unix_permissions` — which UNIX permissions to set, normally the default should be used
    # 
    # _@return_ — without a block - the Writable sink which has to be closed manually
    sig do
      params(
        filename: String,
        modification_time: Time,
        unix_permissions: T.nilable(Integer),
        blk: T.proc.params(sink: ZipKit::Streamer::Writable).void
      ).returns(ZipKit::Streamer::Writable)
    end
    def write_file(filename, modification_time: Time.now.utc, unix_permissions: nil, &blk); end

    # Opens the stream for a stored file in the archive, and yields a writer
    # for that file to the block.
    # Once the write completes, a data descriptor will be written with the
    # actual compressed/uncompressed sizes and the CRC32 checksum.
    # 
    # Using a block, the write will be terminated with a data descriptor outright.
    # 
    #     zip.write_stored_file("foo.txt") do |sink|
    #       IO.copy_stream(source_file, sink)
    #     end
    # 
    # If deferred writes are desired (for example - to integrate with an API that
    # does not support blocks, or to work with non-blocking environments) the method
    # has to be called without a block. In that case it returns the sink instead,
    # permitting to write to it in a deferred fashion. When `close` is called on
    # the sink, any remanining compression output will be flushed and the data
    # descriptor is going to be written.
    # 
    # Note that even though it does not have to happen within the same call stack,
    # call sequencing still must be observed. It is therefore not possible to do
    # this:
    # 
    #     writer_for_file1 = zip.write_stored_file("somefile.jpg")
    #     writer_for_file2 = zip.write_stored_file("another.tif")
    #     writer_for_file1 << data
    #     writer_for_file2 << data
    # 
    # because it is likely to result in an invalid ZIP file structure later on.
    # So using this facility in async scenarios is certainly possible, but care
    # and attention is recommended.
    # 
    # If an exception is raised inside the block that is passed to the method, a `rollback!` call
    # will be performed automatically and the entry just written will be omitted from the ZIP
    # central directory. This can be useful if you want to rescue the exception and reattempt
    # adding the ZIP file. Note that you will need to call `write_deflated_file` again to start a
    # new file - you can't keep writing to the one that failed.
    # 
    # _@param_ `filename` — the name of the file in the archive
    # 
    # _@param_ `modification_time` — the modification time of the file in the archive
    # 
    # _@param_ `unix_permissions` — which UNIX permissions to set, normally the default should be used
    # 
    # _@return_ — without a block - the Writable sink which has to be closed manually
    sig do
      params(
        filename: String,
        modification_time: Time,
        unix_permissions: T.nilable(Integer),
        blk: T.proc.params(sink: ZipKit::Streamer::Writable).void
      ).returns(ZipKit::Streamer::Writable)
    end
    def write_stored_file(filename, modification_time: Time.now.utc, unix_permissions: nil, &blk); end

    # Opens the stream for a deflated file in the archive, and yields a writer
    # for that file to the block. Once the write completes, a data descriptor
    # will be written with the actual compressed/uncompressed sizes and the
    # CRC32 checksum.
    # 
    # Using a block, the write will be terminated with a data descriptor outright.
    # 
    #     zip.write_stored_file("foo.txt") do |sink|
    #       IO.copy_stream(source_file, sink)
    #     end
    # 
    # If deferred writes are desired (for example - to integrate with an API that
    # does not support blocks, or to work with non-blocking environments) the method
    # has to be called without a block. In that case it returns the sink instead,
    # permitting to write to it in a deferred fashion. When `close` is called on
    # the sink, any remanining compression output will be flushed and the data
    # descriptor is going to be written.
    # 
    # Note that even though it does not have to happen within the same call stack,
    # call sequencing still must be observed. It is therefore not possible to do
    # this:
    # 
    #     writer_for_file1 = zip.write_deflated_file("somefile.jpg")
    #     writer_for_file2 = zip.write_deflated_file("another.tif")
    #     writer_for_file1 << data
    #     writer_for_file2 << data
    #     writer_for_file1.close
    #     writer_for_file2.close
    # 
    # because it is likely to result in an invalid ZIP file structure later on.
    # So using this facility in async scenarios is certainly possible, but care
    # and attention is recommended.
    # 
    # If an exception is raised inside the block that is passed to the method, a `rollback!` call
    # will be performed automatically and the entry just written will be omitted from the ZIP
    # central directory. This can be useful if you want to rescue the exception and reattempt
    # adding the ZIP file. Note that you will need to call `write_deflated_file` again to start a
    # new file - you can't keep writing to the one that failed.
    # 
    # _@param_ `filename` — the name of the file in the archive
    # 
    # _@param_ `modification_time` — the modification time of the file in the archive
    # 
    # _@param_ `unix_permissions` — which UNIX permissions to set, normally the default should be used
    # 
    # _@return_ — without a block - the Writable sink which has to be closed manually
    sig do
      params(
        filename: String,
        modification_time: Time,
        unix_permissions: T.nilable(Integer),
        blk: T.proc.params(sink: ZipKit::Streamer::Writable).void
      ).returns(ZipKit::Streamer::Writable)
    end
    def write_deflated_file(filename, modification_time: Time.now.utc, unix_permissions: nil, &blk); end

    # Closes the archive. Writes the central directory, and switches the writer into
    # a state where it can no longer be written to.
    # 
    # Once this method is called, the `Streamer` should be discarded (the ZIP archive is complete).
    # 
    # _@return_ — the offset the output IO is at after closing the archive
    sig { returns(Integer) }
    def close; end

    # Sets up the ZipWriter with wrappers if necessary. The method is called once, when the Streamer
    # gets instantiated - the Writer then gets reused. This method is primarily there so that you
    # can override it.
    # 
    # _@return_ — the writer to perform writes with
    sig { returns(ZipKit::ZipWriter) }
    def create_writer; end

    # Updates the last entry written with the CRC32 checksum and compressed/uncompressed
    # sizes. For stored entries, `compressed_size` and `uncompressed_size` are the same.
    # After updating the entry will immediately write the data descriptor bytes
    # to the output.
    # 
    # _@param_ `crc32` — the CRC32 checksum of the entry when uncompressed
    # 
    # _@param_ `compressed_size` — the size of the compressed segment within the ZIP
    # 
    # _@param_ `uncompressed_size` — the size of the entry once uncompressed
    # 
    # _@return_ — the offset the output IO is at after writing the data descriptor
    sig { params(crc32: Integer, compressed_size: Integer, uncompressed_size: Integer).returns(Integer) }
    def update_last_entry_and_write_data_descriptor(crc32:, compressed_size:, uncompressed_size:); end

    # Removes the buffered local entry for the last file written. This can be used when rescuing from exceptions
    # when you want to skip the file that failed writing into the ZIP from getting written out into the
    # ZIP central directory. This is useful when, for example, you encounter errors retrieving the file
    # that you want to place inside the ZIP from a remote storage location and some network exception
    # gets raised. `write_deflated_file` and `write_stored_file` will rollback for you automatically.
    # Of course it is not possible to remove the failed entry from the ZIP file entirely, as the data
    # is likely already on the wire. However, excluding the entry from the central directory of the ZIP
    # file will allow better-behaved ZIP unarchivers to extract the entries which did store correctly,
    # provided they read the ZIP from the central directory and not straight-ahead.
    # 
    # _@return_ — position in the output stream / ZIP archive
    # 
    # ```ruby
    # zip.add_stored_entry(filename: "data.bin", size: 4.megabytes, crc32: the_crc)
    # while chunk = remote.read(65*2048)
    #   zip << chunk
    # rescue Timeout::Error
    #   zip.rollback!
    #   # and proceed to the next file
    # end
    # ```
    sig { returns(Integer) }
    def rollback!; end

    # sord omit - no YARD type given for "writable", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(writable: T.untyped, block_to_pass_writable_to: T.untyped).returns(T.untyped) }
    def yield_or_return_writable(writable, &block_to_pass_writable_to); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def verify_offsets!; end

    # sord omit - no YARD type given for "filename:", using untyped
    # sord omit - no YARD type given for "modification_time:", using untyped
    # sord omit - no YARD type given for "crc32:", using untyped
    # sord omit - no YARD type given for "storage_mode:", using untyped
    # sord omit - no YARD type given for "compressed_size:", using untyped
    # sord omit - no YARD type given for "uncompressed_size:", using untyped
    # sord omit - no YARD type given for "use_data_descriptor:", using untyped
    # sord omit - no YARD type given for "unix_permissions:", using untyped
    # sord omit - no YARD return type given, using untyped
    sig do
      params(
        filename: T.untyped,
        modification_time: T.untyped,
        crc32: T.untyped,
        storage_mode: T.untyped,
        compressed_size: T.untyped,
        uncompressed_size: T.untyped,
        use_data_descriptor: T.untyped,
        unix_permissions: T.untyped
      ).returns(T.untyped)
    end
    def add_file_and_write_local_header(filename:, modification_time:, crc32:, storage_mode:, compressed_size:, uncompressed_size:, use_data_descriptor:, unix_permissions:); end

    # sord omit - no YARD type given for "filename", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(filename: T.untyped).returns(T.untyped) }
    def remove_backslash(filename); end

    # sord infer - argument name in single @param inferred as "bytes"
    # Writes the given data to the output stream. Allows the object to be used as
    # a target for `IO.copy_stream(from, to)`
    # 
    # _@param_ `d` — the binary string to write (part of the uncompressed file)
    # 
    # _@return_ — the number of bytes written
    sig { params(bytes: String).returns(Fixnum) }
    def write(bytes); end

    # Is used internally by Streamer to keep track of entries in the archive during writing.
    # Normally you will not have to use this class directly
    class Entry < Struct
      sig { void }
      def initialize; end

      # sord omit - no YARD return type given, using untyped
      sig { returns(T.untyped) }
      def total_bytes_used; end

      # sord omit - no YARD return type given, using untyped
      # Set the general purpose flags for the entry. We care about is the EFS
      # bit (bit 11) which should be set if the filename is UTF8. If it is, we need to set the
      # bit so that the unarchiving application knows that the filename in the archive is UTF-8
      # encoded, and not some DOS default. For ASCII entries it does not matter.
      # Additionally, we care about bit 3 which toggles the use of the postfix data descriptor.
      sig { returns(T.untyped) }
      def gp_flags; end

      sig { returns(T::Boolean) }
      def filler?; end

      # Returns the value of attribute filename
      sig { returns(Object) }
      attr_accessor :filename

      # Returns the value of attribute crc32
      sig { returns(Object) }
      attr_accessor :crc32

      # Returns the value of attribute compressed_size
      sig { returns(Object) }
      attr_accessor :compressed_size

      # Returns the value of attribute uncompressed_size
      sig { returns(Object) }
      attr_accessor :uncompressed_size

      # Returns the value of attribute storage_mode
      sig { returns(Object) }
      attr_accessor :storage_mode

      # Returns the value of attribute mtime
      sig { returns(Object) }
      attr_accessor :mtime

      # Returns the value of attribute use_data_descriptor
      sig { returns(Object) }
      attr_accessor :use_data_descriptor

      # Returns the value of attribute local_header_offset
      sig { returns(Object) }
      attr_accessor :local_header_offset

      # Returns the value of attribute bytes_used_for_local_header
      sig { returns(Object) }
      attr_accessor :bytes_used_for_local_header

      # Returns the value of attribute bytes_used_for_data_descriptor
      sig { returns(Object) }
      attr_accessor :bytes_used_for_data_descriptor

      # Returns the value of attribute unix_permissions
      sig { returns(Object) }
      attr_accessor :unix_permissions
    end

    # Is used internally by Streamer to keep track of entries in the archive during writing.
    # Normally you will not have to use this class directly
    class Filler < Struct
      sig { returns(T::Boolean) }
      def filler?; end

      # Returns the value of attribute total_bytes_used
      sig { returns(Object) }
      attr_accessor :total_bytes_used
    end

    # Gets yielded from the writing methods of the Streamer
    # and accepts the data being written into the ZIP for deflate
    # or stored modes. Can be used as a destination for `IO.copy_stream`
    # 
    #    IO.copy_stream(File.open('source.bin', 'rb), writable)
    class Writable
      include ZipKit::WriteShovel

      # sord omit - no YARD type given for "streamer", using untyped
      # sord omit - no YARD type given for "writer", using untyped
      # Initializes a new Writable with the object it delegates the writes to.
      # Normally you would not need to use this method directly
      sig { params(streamer: T.untyped, writer: T.untyped).void }
      def initialize(streamer, writer); end

      # Writes the given data to the output stream
      # 
      # _@param_ `d` — the binary string to write (part of the uncompressed file)
      sig { params(d: String).returns(T.self_type) }
      def <<(d); end

      # sord omit - no YARD return type given, using untyped
      # Flushes the writer and recovers the CRC32/size values. It then calls
      # `update_last_entry_and_write_data_descriptor` on the given Streamer.
      sig { returns(T.untyped) }
      def close; end

      # sord infer - argument name in single @param inferred as "bytes"
      # Writes the given data to the output stream. Allows the object to be used as
      # a target for `IO.copy_stream(from, to)`
      # 
      # _@param_ `d` — the binary string to write (part of the uncompressed file)
      # 
      # _@return_ — the number of bytes written
      sig { params(bytes: String).returns(Fixnum) }
      def write(bytes); end
    end

    # Will be used to pick whether to store a file in the `stored` or
    # `deflated` mode, by compressing the first N bytes of the file and
    # comparing the stored and deflated data sizes. If deflate produces
    # a sizable compression gain for this data, it will create a deflated
    # file inside the ZIP archive. If the file doesn't compress well, it
    # will use the "stored" mode for the entry. About 128KB of the
    # file will be buffered to pick the appropriate storage mode. The
    # Heuristic will call either `write_stored_file` or `write_deflated_file`
    # on the Streamer passed into it once it knows which compression
    # method should be applied
    class Heuristic < ZipKit::Streamer::Writable
      BYTES_WRITTEN_THRESHOLD = T.let(128 * 1024, T.untyped)
      MINIMUM_VIABLE_COMPRESSION = T.let(0.75, T.untyped)

      # sord omit - no YARD type given for "streamer", using untyped
      # sord omit - no YARD type given for "filename", using untyped
      # sord omit - no YARD type given for "**write_file_options", using untyped
      sig { params(streamer: T.untyped, filename: T.untyped, write_file_options: T.untyped).void }
      def initialize(streamer, filename, **write_file_options); end

      # sord infer - argument name in single @param inferred as "bytes"
      sig { params(bytes: String).returns(T.self_type) }
      def <<(bytes); end

      # sord omit - no YARD return type given, using untyped
      sig { returns(T.untyped) }
      def close; end

      # sord omit - no YARD return type given, using untyped
      sig { returns(T.untyped) }
      def decide; end
    end

    # Sends writes to the given `io`, and also registers all the data passing
    # through it in a CRC32 checksum calculator. Is made to be completely
    # interchangeable with the DeflatedWriter in terms of interface.
    class StoredWriter
      include ZipKit::WriteShovel
      CRC32_BUFFER_SIZE = T.let(64 * 1024, T.untyped)

      # sord omit - no YARD type given for "io", using untyped
      sig { params(io: T.untyped).void }
      def initialize(io); end

      # Writes the given data to the contained IO object.
      # 
      # _@param_ `data` — data to be written
      # 
      # _@return_ — self
      sig { params(data: String).returns(T.untyped) }
      def <<(data); end

      # Returns the amount of data written and the CRC32 checksum. The return value
      # can be directly used as the argument to {Streamer#update_last_entry_and_write_data_descriptor}
      # 
      # _@return_ — a hash of `{crc32, compressed_size, uncompressed_size}`
      sig { returns(T::Hash[T.untyped, T.untyped]) }
      def finish; end

      # sord infer - argument name in single @param inferred as "bytes"
      # Writes the given data to the output stream. Allows the object to be used as
      # a target for `IO.copy_stream(from, to)`
      # 
      # _@param_ `d` — the binary string to write (part of the uncompressed file)
      # 
      # _@return_ — the number of bytes written
      sig { params(bytes: String).returns(Fixnum) }
      def write(bytes); end
    end

    # Sends writes to the given `io` compressed using a `Zlib::Deflate`. Also
    # registers data passing through it in a CRC32 checksum calculator. Is made to be completely
    # interchangeable with the StoredWriter in terms of interface.
    class DeflatedWriter
      include ZipKit::WriteShovel
      CRC32_BUFFER_SIZE = T.let(64 * 1024, T.untyped)

      # sord omit - no YARD type given for "io", using untyped
      sig { params(io: T.untyped).void }
      def initialize(io); end

      # Writes the given data into the deflater, and flushes the deflater
      # after having written more than FLUSH_EVERY_N_BYTES bytes of data
      # 
      # _@param_ `data` — data to be written
      # 
      # _@return_ — self
      sig { params(data: String).returns(T.untyped) }
      def <<(data); end

      # Returns the amount of data received for writing, the amount of
      # compressed data written and the CRC32 checksum. The return value
      # can be directly used as the argument to {Streamer#update_last_entry_and_write_data_descriptor}
      # 
      # _@return_ — a hash of `{crc32, compressed_size, uncompressed_size}`
      sig { returns(T::Hash[T.untyped, T.untyped]) }
      def finish; end

      # sord infer - argument name in single @param inferred as "bytes"
      # Writes the given data to the output stream. Allows the object to be used as
      # a target for `IO.copy_stream(from, to)`
      # 
      # _@param_ `d` — the binary string to write (part of the uncompressed file)
      # 
      # _@return_ — the number of bytes written
      sig { params(bytes: String).returns(Fixnum) }
      def write(bytes); end
    end
  end

  # An object that fakes just-enough of an IO to be dangerous
  # - or, more precisely, to be useful as a source for the FileReader
  # central directory parser. Effectively we substitute an IO object
  # for an object that fetches parts of the remote file over HTTP using `Range:`
  # headers. The `RemoteIO` acts as an adapter between an object that performs the
  # actual fetches over HTTP and an object that expects a handful of IO methods to be
  # available.
  class RemoteIO
    # sord warn - URI wasn't able to be resolved to a constant in this project
    # _@param_ `url` — the HTTP/HTTPS URL of the object to be retrieved
    sig { params(url: T.any(String, URI)).void }
    def initialize(url); end

    # sord omit - no YARD return type given, using untyped
    # Emulates IO#seek
    # 
    # _@param_ `offset` — absolute offset in the remote resource to seek to
    # 
    # _@param_ `mode` — The seek mode (only SEEK_SET is supported)
    sig { params(offset: Integer, mode: Integer).returns(T.untyped) }
    def seek(offset, mode = IO::SEEK_SET); end

    # Emulates IO#size.
    # 
    # _@return_ — the size of the remote resource
    sig { returns(Integer) }
    def size; end

    # Emulates IO#read, but requires the number of bytes to read
    # The read will be limited to the
    # size of the remote resource relative to the current offset in the IO,
    # so if you are at offset 0 in the IO of size 10, doing a `read(20)`
    # will only return you 10 bytes of result, and not raise any exceptions.
    # 
    # _@param_ `n_bytes` — how many bytes to read, or `nil` to read all the way to the end
    # 
    # _@return_ — the read bytes
    sig { params(n_bytes: T.nilable(Fixnum)).returns(String) }
    def read(n_bytes = nil); end

    # Returns the current pointer position within the IO
    sig { returns(Fixnum) }
    def tell; end

    # Only used internally when reading the remote ZIP.
    # 
    # _@param_ `range` — the HTTP range of data to fetch from remote
    # 
    # _@return_ — the response body of the ranged request
    sig { params(range: T::Range[T.untyped]).returns(String) }
    def request_range(range); end

    # For working with S3 it is a better idea to perform a GET request for one byte, since doing a HEAD
    # request needs a different permission - and standard GET presigned URLs are not allowed to perform it
    # 
    # _@return_ — the size of the remote resource, parsed either from Content-Length or Content-Range header
    sig { returns(Integer) }
    def request_object_size; end

    # sord omit - no YARD type given for "a", using untyped
    # sord omit - no YARD type given for "b", using untyped
    # sord omit - no YARD type given for "c", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(a: T.untyped, b: T.untyped, c: T.untyped).returns(T.untyped) }
    def clamp(a, b, c); end
  end

  # A low-level ZIP file data writer. You can use it to write out various headers and central directory elements
  # separately. The class handles the actual encoding of the data according to the ZIP format APPNOTE document.
  # 
  # The primary reason the writer is a separate object is because it is kept stateless. That is, all the data that
  # is needed for writing a piece of the ZIP (say, the EOCD record, or a data descriptor) can be written
  # without depending on data available elsewhere. This makes the writer very easy to test, since each of
  # it's methods outputs something that only depends on the method's arguments. For example, we use this
  # to test writing Zip64 files which, when tested in a streaming fashion, would need tricky IO stubs
  # to wind IO objects back and forth by large offsets. Instead, we can just write out the EOCD record
  # with given offsets as arguments.
  # 
  # Since some methods need a lot of data about the entity being written, everything is passed via
  # keyword arguments - this way it is much less likely that you can make a mistake writing something.
  # 
  # Another reason for having a separate Writer is that most ZIP libraries attach the methods for
  # writing out the file headers to some sort of Entry object, which represents a file within the ZIP.
  # However, when you are diagnosing issues with the ZIP files you produce, you actually want to have
  # absolute _most_ of the code responsible for writing the actual encoded bytes available to you on
  # one screen. Altering or checking that code then becomes much, much easier. The methods doing the
  # writing are also intentionally left very verbose - so that you can follow what is happening at
  # all times.
  # 
  # All methods of the writer accept anything that responds to `<<` as `io` argument - you can use
  # that to output to String objects, or to output to Arrays that you can later join together.
  class ZipWriter
    FOUR_BYTE_MAX_UINT = T.let(0xFFFFFFFF, T.untyped)
    TWO_BYTE_MAX_UINT = T.let(0xFFFF, T.untyped)
    ZIP_KIT_COMMENT = T.let("Written using ZipKit %<version>s" % {version: ZipKit::VERSION}, T.untyped)
    VERSION_MADE_BY = T.let(52, T.untyped)
    VERSION_NEEDED_TO_EXTRACT = T.let(20, T.untyped)
    VERSION_NEEDED_TO_EXTRACT_ZIP64 = T.let(45, T.untyped)
    DEFAULT_FILE_UNIX_PERMISSIONS = T.let(0o644, T.untyped)
    DEFAULT_DIRECTORY_UNIX_PERMISSIONS = T.let(0o755, T.untyped)
    FILE_TYPE_FILE = T.let(0o10, T.untyped)
    FILE_TYPE_DIRECTORY = T.let(0o04, T.untyped)
    MADE_BY_SIGNATURE = T.let(begin
  # A combination of the VERSION_MADE_BY low byte and the OS type high byte
  os_type = 3 # UNIX
  [VERSION_MADE_BY, os_type].pack("CC")
end, T.untyped)
    C_UINT4 = T.let("V", T.untyped)
    C_UINT2 = T.let("v", T.untyped)
    C_UINT8 = T.let("Q<", T.untyped)
    C_CHAR = T.let("C", T.untyped)
    C_INT4 = T.let("l<", T.untyped)

    # sord duck - #<< looks like a duck type, replacing with untyped
    # Writes the local file header, that precedes the actual file _data_.
    # 
    # _@param_ `io` — the buffer to write the local file header to
    # 
    # _@param_ `filename` — the name of the file in the archive
    # 
    # _@param_ `compressed_size` — The size of the compressed (or stored) data - how much space it uses in the ZIP
    # 
    # _@param_ `uncompressed_size` — The size of the file once extracted
    # 
    # _@param_ `crc32` — The CRC32 checksum of the file
    # 
    # _@param_ `mtime` — the modification time to be recorded in the ZIP
    # 
    # _@param_ `gp_flags` — bit-packed general purpose flags
    # 
    # _@param_ `storage_mode` — 8 for deflated, 0 for stored...
    sig do
      params(
        io: T.untyped,
        filename: String,
        compressed_size: Fixnum,
        uncompressed_size: Fixnum,
        crc32: Fixnum,
        gp_flags: Fixnum,
        mtime: Time,
        storage_mode: Fixnum
      ).void
    end
    def write_local_file_header(io:, filename:, compressed_size:, uncompressed_size:, crc32:, gp_flags:, mtime:, storage_mode:); end

    # sord duck - #<< looks like a duck type, replacing with untyped
    # sord omit - no YARD type given for "local_file_header_location:", using untyped
    # sord omit - no YARD type given for "storage_mode:", using untyped
    # Writes the file header for the central directory, for a particular file in the archive. When writing out this data,
    # ensure that the CRC32 and both sizes (compressed/uncompressed) are correct for the entry in question.
    # 
    # _@param_ `io` — the buffer to write the local file header to
    # 
    # _@param_ `filename` — the name of the file in the archive
    # 
    # _@param_ `compressed_size` — The size of the compressed (or stored) data - how much space it uses in the ZIP
    # 
    # _@param_ `uncompressed_size` — The size of the file once extracted
    # 
    # _@param_ `crc32` — The CRC32 checksum of the file
    # 
    # _@param_ `mtime` — the modification time to be recorded in the ZIP
    # 
    # _@param_ `gp_flags` — bit-packed general purpose flags
    # 
    # _@param_ `unix_permissions` — the permissions for the file, or nil for the default to be used
    sig do
      params(
        io: T.untyped,
        local_file_header_location: T.untyped,
        gp_flags: Fixnum,
        storage_mode: T.untyped,
        compressed_size: Fixnum,
        uncompressed_size: Fixnum,
        mtime: Time,
        crc32: Fixnum,
        filename: String,
        unix_permissions: T.nilable(Integer)
      ).void
    end
    def write_central_directory_file_header(io:, local_file_header_location:, gp_flags:, storage_mode:, compressed_size:, uncompressed_size:, mtime:, crc32:, filename:, unix_permissions: nil); end

    # sord duck - #<< looks like a duck type, replacing with untyped
    # Writes the data descriptor following the file data for a file whose local file header
    # was written with general-purpose flag bit 3 set. If the one of the sizes exceeds the Zip64 threshold,
    # the data descriptor will have the sizes written out as 8-byte values instead of 4-byte values.
    # 
    # _@param_ `io` — the buffer to write the local file header to
    # 
    # _@param_ `crc32` — The CRC32 checksum of the file
    # 
    # _@param_ `compressed_size` — The size of the compressed (or stored) data - how much space it uses in the ZIP
    # 
    # _@param_ `uncompressed_size` — The size of the file once extracted
    sig do
      params(
        io: T.untyped,
        compressed_size: Fixnum,
        uncompressed_size: Fixnum,
        crc32: Fixnum
      ).void
    end
    def write_data_descriptor(io:, compressed_size:, uncompressed_size:, crc32:); end

    # sord duck - #<< looks like a duck type, replacing with untyped
    # Writes the "end of central directory record" (including the Zip6 salient bits if necessary)
    # 
    # _@param_ `io` — the buffer to write the central directory to.
    # 
    # _@param_ `start_of_central_directory_location` — byte offset of the start of central directory form the beginning of ZIP file
    # 
    # _@param_ `central_directory_size` — the size of the central directory (only file headers) in bytes
    # 
    # _@param_ `num_files_in_archive` — How many files the archive contains
    # 
    # _@param_ `comment` — the comment for the archive (defaults to ZIP_KIT_COMMENT)
    sig do
      params(
        io: T.untyped,
        start_of_central_directory_location: Fixnum,
        central_directory_size: Fixnum,
        num_files_in_archive: Fixnum,
        comment: String
      ).void
    end
    def write_end_of_central_directory(io:, start_of_central_directory_location:, central_directory_size:, num_files_in_archive:, comment: ZIP_KIT_COMMENT); end

    # Writes the Zip64 extra field for the local file header. Will be used by `write_local_file_header` when any sizes given to it warrant that.
    # 
    # _@param_ `compressed_size` — The size of the compressed (or stored) data - how much space it uses in the ZIP
    # 
    # _@param_ `uncompressed_size` — The size of the file once extracted
    sig { params(compressed_size: Fixnum, uncompressed_size: Fixnum).returns(String) }
    def zip_64_extra_for_local_file_header(compressed_size:, uncompressed_size:); end

    # sord omit - no YARD type given for "mtime", using untyped
    # sord omit - no YARD return type given, using untyped
    # Writes the extended timestamp information field for local headers.
    # 
    # The spec defines 2
    # different formats - the one for the local file header can also accomodate the
    # atime and ctime, whereas the one for the central directory can only take
    # the mtime - and refers the reader to the local header extra to obtain the
    # remaining times
    sig { params(mtime: T.untyped).returns(T.untyped) }
    def timestamp_extra_for_local_file_header(mtime); end

    # Writes the Zip64 extra field for the central directory header.It differs from the extra used in the local file header because it
    # also contains the location of the local file header in the ZIP as an 8-byte int.
    # 
    # _@param_ `compressed_size` — The size of the compressed (or stored) data - how much space it uses in the ZIP
    # 
    # _@param_ `uncompressed_size` — The size of the file once extracted
    # 
    # _@param_ `local_file_header_location` — Byte offset of the start of the local file header from the beginning of the ZIP archive
    sig { params(compressed_size: Fixnum, uncompressed_size: Fixnum, local_file_header_location: Fixnum).returns(String) }
    def zip_64_extra_for_central_directory_file_header(compressed_size:, uncompressed_size:, local_file_header_location:); end

    # sord omit - no YARD type given for "t", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(t: T.untyped).returns(T.untyped) }
    def to_binary_dos_time(t); end

    # sord omit - no YARD type given for "t", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(t: T.untyped).returns(T.untyped) }
    def to_binary_dos_date(t); end

    # sord omit - no YARD type given for "values_to_packspecs", using untyped
    # sord omit - no YARD return type given, using untyped
    # Unzips a given array of tuples of "numeric value, pack specifier" and then packs all the odd
    # values using specifiers from all the even values. It is harder to explain than to show:
    # 
    #   pack_array([1, 'V', 2, 'v', 148, 'v]) #=> "\x01\x00\x00\x00\x02\x00\x94\x00"
    # 
    # will do the following two transforms:
    # 
    #  [1, 'V', 2, 'v', 148, 'v] -> [1,2,148], ['V','v','v'] -> [1,2,148].pack('Vvv') -> "\x01\x00\x00\x00\x02\x00\x94\x00".
    # This might seem like a "clever optimisation" but the issue is that `pack` needs an array allocated per call, and
    # we output very verbosely - value-by-value. This might be quite a few array allocs. Using something like this
    # helps us save the array allocs
    sig { params(values_to_packspecs: T.untyped).returns(T.untyped) }
    def pack_array(values_to_packspecs); end

    # sord omit - no YARD type given for "unix_permissions_int", using untyped
    # sord omit - no YARD type given for "file_type_int", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(unix_permissions_int: T.untyped, file_type_int: T.untyped).returns(T.untyped) }
    def generate_external_attrs(unix_permissions_int, file_type_int); end
  end

  # Acts as a converter between callers which send data to the `#<<` method (such as all the ZipKit
  # writer methods, which push onto anything), and a given block. Every time `#<<` gets called on the BlockWrite,
  # the block given to the constructor will be called with the same argument. ZipKit uses this object
  # when integrating with Rack and in the OutputEnumerator. Normally you wouldn't need to use it manually but
  # you always can. BlockWrite will also ensure the binary string encoding is forced onto any string
  # that passes through it.
  # 
  # For example, you can create a Rack response body like so:
  # 
  #     class MyRackResponse
  #       def each
  #         writer = ZipKit::BlockWrite.new {|chunk| yield(chunk) }
  #         writer << "Hello" << "world" << "!"
  #       end
  #     end
  #     [200, {}, MyRackResponse.new]
  class BlockWrite
    # Creates a new BlockWrite.
    # 
    # _@param_ `block` — The block that will be called when this object receives the `<<` message
    sig { params(block: T.untyped).void }
    def initialize(&block); end

    # Sends a string through to the block stored in the BlockWrite.
    # 
    # _@param_ `buf` — the string to write. Note that a zero-length String will not be forwarded to the block, as it has special meaning when used with chunked encoding (it indicates the end of the stream).
    # 
    # _@return_ — self
    sig { params(buf: String).returns(T.untyped) }
    def <<(buf); end
  end

  # A very barebones ZIP file reader. Is made for maximum interoperability, but at the same
  # time we attempt to keep it somewhat concise.
  # 
  # ## REALLY CRAZY IMPORTANT STUFF: SECURITY IMPLICATIONS
  # 
  # Please **BEWARE** - using this is a security risk if you are reading files that have been
  # supplied by users. This implementation has _not_ been formally verified for correctness. As
  # ZIP files contain relative offsets in lots of places it might be possible for a maliciously
  # crafted ZIP file to put the decode procedure in an endless loop, make it attempt huge reads
  # from the input file and so on. Additionally, the reader module for deflated data has
  # no support for ZIP bomb protection. So either limit the `FileReader` usage to the files you
  # trust, or triple-check all the inputs upfront. Patches to make this reader more secure
  # are welcome of course.
  # 
  # ## Usage
  # 
  #     File.open('zipfile.zip', 'rb') do |f|
  #       entries = ZipKit::FileReader.read_zip_structure(io: f)
  #       entries.each do |e|
  #         File.open(e.filename, 'wb') do |extracted_file|
  #           ex = e.extractor_from(f)
  #           extracted_file << ex.extract(1024 * 1024) until ex.eof?
  #         end
  #       end
  #     end
  # 
  # ## Supported features
  # 
  # * Deflate and stored storage modes
  # * Zip64 (extra fields and offsets)
  # * Data descriptors
  # 
  # ## Unsupported features
  # 
  # * Archives split over multiple disks/files
  # * Any ZIP encryption
  # * EFS language flag and InfoZIP filename extra field
  # * CRC32 checksums are _not_ verified
  # 
  # ## Mode of operation
  # 
  # By default, `FileReader` _ignores_ the data in local file headers (as it is
  # often unreliable). It reads the ZIP file "from the tail", finds the
  # end-of-central-directory signatures, then reads the central directory entries,
  # reconstitutes the entries with their filenames, attributes and so on, and
  # sets these entries up with the absolute _offsets_ into the source file/IO object.
  # These offsets can then be used to extract the actual compressed data of
  # the files and to expand it.
  # 
  # ## Recovering damaged or incomplete ZIP files
  # 
  # If the ZIP file you are trying to read does not contain the central directory
  # records `read_zip_structure` will not work, since it starts the read process
  # from the EOCD marker at the end of the central directory and then crawls
  # "back" in the IO to figure out the rest. You can explicitly apply a fallback
  # for reading the archive "straight ahead" instead using `read_zip_straight_ahead`
  # - the method will instead scan your IO from the very start, skipping over
  # the actual entry data. This is less efficient than central directory parsing since
  # it involves a much larger number of reads (1 read from the IO per entry in the ZIP).
  class FileReader
    ReadError = T.let(Class.new(StandardError), T.untyped)
    UnsupportedFeature = T.let(Class.new(StandardError), T.untyped)
    InvalidStructure = T.let(Class.new(ReadError), T.untyped)
    LocalHeaderPending = T.let(Class.new(StandardError) do
  def message
    "The compressed data offset is not available (local header has not been read)"
  end
end, T.untyped)
    MissingEOCD = T.let(Class.new(StandardError) do
  def message
    "Could not find the EOCD signature in the buffer - maybe a malformed ZIP file"
  end
end, T.untyped)
    C_UINT4 = T.let("V", T.untyped)
    C_UINT2 = T.let("v", T.untyped)
    C_UINT8 = T.let("Q<", T.untyped)
    MAX_END_OF_CENTRAL_DIRECTORY_RECORD_SIZE = T.let(4 + # Offset of the start of central directory
4 + # Size of the central directory
2 + # Number of files in the cdir
4 + # End-of-central-directory signature
2 + # Number of this disk
2 + # Number of disk with the start of cdir
2 + # Number of files in the cdir of this disk
2 + # The comment size
0xFFFF, T.untyped)
    MAX_LOCAL_HEADER_SIZE = T.let(4 + # signature
2 + # Version needed to extract
2 + # gp flags
2 + # storage mode
2 + # dos time
2 + # dos date
4 + # CRC32
4 + # Comp size
4 + # Uncomp size
2 + # Filename size
2 + # Extra fields size
0xFFFF + # Maximum filename size
0xFFFF, T.untyped)
    SIZE_OF_USABLE_EOCD_RECORD = T.let(4 + # Signature
2 + # Number of this disk
2 + # Number of the disk with the EOCD record
2 + # Number of entries in the central directory of this disk
2 + # Number of entries in the central directory total
4 + # Size of the central directory
4, T.untyped)

    # sord duck - #tell looks like a duck type, replacing with untyped
    # sord duck - #seek looks like a duck type, replacing with untyped
    # sord duck - #read looks like a duck type, replacing with untyped
    # sord duck - #size looks like a duck type, replacing with untyped
    # Parse an IO handle to a ZIP archive into an array of Entry objects.
    # 
    # _@param_ `io` — an IO-ish object
    # 
    # _@param_ `read_local_headers` — whether the local headers must be read upfront. When reading a locally available ZIP file this option will not have much use since the small reads from the file handle are not going to be that important. However, if you are using remote reads to decipher a ZIP file located on an HTTP server, the operation _must_ perform an HTTP request for _each entry in the ZIP file_ to determine where the actual file data starts. This, for a ZIP archive of 1000 files, will incur 1000 extra HTTP requests - which you might not want to perform upfront, or - at least - not want to perform _at once_. When the option is set to `false`, you will be getting instances of `LazyEntry` instead of `Entry`. Those objects will raise an exception when you attempt to access their compressed data offset in the ZIP (since the reads have not been performed yet). As a rule, this option can be left in it's default setting (`true`) unless you want to _only_ read the central directory, or you need to limit the number of HTTP requests.
    # 
    # _@return_ — an array of entries within the ZIP being parsed
    sig { params(io: T.untyped, read_local_headers: T::Boolean).returns(T::Array[ZipEntry]) }
    def read_zip_structure(io:, read_local_headers: true); end

    # sord duck - #tell looks like a duck type, replacing with untyped
    # sord duck - #read looks like a duck type, replacing with untyped
    # sord duck - #seek looks like a duck type, replacing with untyped
    # sord omit - no YARD return type given, using untyped
    # Sometimes you might encounter truncated ZIP files, which do not contain
    # any central directory whatsoever - or where the central directory is
    # truncated. In that case, employing the technique of reading the ZIP
    # "from the end" is impossible, and the only recourse is reading each
    # local file header in sucession. If the entries in such a ZIP use data
    # descriptors, you would need to scan after the entry until you encounter
    # the data descriptor signature - and that might be unreliable at best.
    # Therefore, this reading technique does not support data descriptors.
    # It can however recover the entries you still can read if these entries
    # contain all the necessary information about the contained file.
    # 
    # headers from @return [Array<ZipEntry>] an array of entries that could be
    # recovered before hitting EOF
    # 
    # _@param_ `io` — the IO-ish object to read the local file
    sig { params(io: T.untyped).returns(T.untyped) }
    def read_zip_straight_ahead(io:); end

    # sord duck - #read looks like a duck type, replacing with untyped
    # Parse the local header entry and get the offset in the IO at which the
    # actual compressed data of the file starts within the ZIP.
    # The method will eager-read the entire local header for the file
    # (the maximum size the local header may use), starting at the given offset,
    # and will then compute its size. That size plus the local header offset
    # given will be the compressed data offset of the entry (read starting at
    # this offset to get the data).
    # 
    # the compressed data offset
    # 
    # _@param_ `io` — an IO-ish object the ZIP file can be read from
    # 
    # _@return_ — the parsed local header entry and
    sig { params(io: T.untyped).returns(T::Array[T.any(ZipEntry, Fixnum)]) }
    def read_local_file_header(io:); end

    # sord duck - #seek looks like a duck type, replacing with untyped
    # sord duck - #read looks like a duck type, replacing with untyped
    # sord omit - no YARD return type given, using untyped
    # Get the offset in the IO at which the actual compressed data of the file
    # starts within the ZIP. The method will eager-read the entire local header
    # for the file (the maximum size the local header may use), starting at the
    # given offset, and will then compute its size. That size plus the local
    # header offset given will be the compressed data offset of the entry
    # (read starting at this offset to get the data).
    # 
    # local file header is supposed to begin @return [Fixnum] absolute offset
    # (0-based) of where the compressed data begins for this file within the ZIP
    # 
    # _@param_ `io` — an IO-ish object the ZIP file can be read from
    # 
    # _@param_ `local_file_header_offset` — absolute offset (0-based) where the
    sig { params(io: T.untyped, local_file_header_offset: Fixnum).returns(T.untyped) }
    def get_compressed_data_offset(io:, local_file_header_offset:); end

    # Parse an IO handle to a ZIP archive into an array of Entry objects, reading from the end
    # of the IO object.
    # 
    # _@param_ `options` — any options the instance method of the same name accepts
    # 
    # _@return_ — an array of entries within the ZIP being parsed
    # 
    # _@see_ `#read_zip_structure`
    sig { params(options: T::Hash[T.untyped, T.untyped]).returns(T::Array[ZipEntry]) }
    def self.read_zip_structure(**options); end

    # Parse an IO handle to a ZIP archive into an array of Entry objects, reading from the start of
    # the file and parsing local file headers one-by-one
    # 
    # _@param_ `options` — any options the instance method of the same name accepts
    # 
    # _@return_ — an array of entries within the ZIP being parsed
    # 
    # _@see_ `#read_zip_straight_ahead`
    sig { params(options: T::Hash[T.untyped, T.untyped]).returns(T::Array[ZipEntry]) }
    def self.read_zip_straight_ahead(**options); end

    # sord omit - no YARD type given for "entries", using untyped
    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(entries: T.untyped, io: T.untyped).returns(T.untyped) }
    def read_local_headers(entries, io); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped).returns(T.untyped) }
    def skip_ahead_2(io); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped).returns(T.untyped) }
    def skip_ahead_4(io); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped).returns(T.untyped) }
    def skip_ahead_8(io); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD type given for "absolute_pos", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped, absolute_pos: T.untyped).returns(T.untyped) }
    def seek(io, absolute_pos); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD type given for "signature_magic_number", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped, signature_magic_number: T.untyped).returns(T.untyped) }
    def assert_signature(io, signature_magic_number); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD type given for "n", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped, n: T.untyped).returns(T.untyped) }
    def skip_ahead_n(io, n); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD type given for "n_bytes", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped, n_bytes: T.untyped).returns(T.untyped) }
    def read_n(io, n_bytes); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped).returns(T.untyped) }
    def read_2b(io); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped).returns(T.untyped) }
    def read_4b(io); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped).returns(T.untyped) }
    def read_8b(io); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(io: T.untyped).returns(T.untyped) }
    def read_cdir_entry(io); end

    # sord omit - no YARD type given for "file_io", using untyped
    # sord omit - no YARD type given for "zip_file_size", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(file_io: T.untyped, zip_file_size: T.untyped).returns(T.untyped) }
    def get_eocd_offset(file_io, zip_file_size); end

    # sord omit - no YARD type given for "of_substring", using untyped
    # sord omit - no YARD type given for "in_string", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(of_substring: T.untyped, in_string: T.untyped).returns(T.untyped) }
    def all_indices_of_substr_in_str(of_substring, in_string); end

    # sord omit - no YARD type given for "in_str", using untyped
    # sord omit - no YARD return type given, using untyped
    # We have to scan the maximum possible number
    # of bytes that the EOCD can theoretically occupy including the comment after it,
    # and we have to find a combination of:
    #   [EOCD signature, <some ZIP medatata>, comment byte size, comment of size]
    # at the end. To do so, we first find all indices of the signature in the trailer
    # string, and then check whether the bytestring starting at the signature and
    # ending at the end of string satisfies that given pattern.
    sig { params(in_str: T.untyped).returns(T.untyped) }
    def locate_eocd_signature(in_str); end

    # sord omit - no YARD type given for "file_io", using untyped
    # sord omit - no YARD type given for "eocd_offset", using untyped
    # sord omit - no YARD return type given, using untyped
    # Find the Zip64 EOCD locator segment offset. Do this by seeking backwards from the
    # EOCD record in the archive by fixed offsets
    #          get_zip64_eocd_location is too high. [15.17/15]
    sig { params(file_io: T.untyped, eocd_offset: T.untyped).returns(T.untyped) }
    def get_zip64_eocd_location(file_io, eocd_offset); end

    # sord omit - no YARD type given for "io", using untyped
    # sord omit - no YARD type given for "zip64_end_of_cdir_location", using untyped
    # sord omit - no YARD return type given, using untyped
    # num_files_and_central_directory_offset_zip64 is too high. [21.12/15]
    sig { params(io: T.untyped, zip64_end_of_cdir_location: T.untyped).returns(T.untyped) }
    def num_files_and_central_directory_offset_zip64(io, zip64_end_of_cdir_location); end

    # sord omit - no YARD type given for "file_io", using untyped
    # sord omit - no YARD type given for "eocd_offset", using untyped
    # sord omit - no YARD return type given, using untyped
    # Start of the central directory offset
    sig { params(file_io: T.untyped, eocd_offset: T.untyped).returns(T.untyped) }
    def num_files_and_central_directory_offset(file_io, eocd_offset); end

    # sord omit - no YARD return type given, using untyped
    # Is provided as a stub to be overridden in a subclass if you need it. Will report
    # during various stages of reading. The log message is contained in the return value
    # of `yield` in the method (the log messages are lazy-evaluated).
    sig { returns(T.untyped) }
    def log; end

    # sord omit - no YARD type given for "extra_fields_str", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(extra_fields_str: T.untyped).returns(T.untyped) }
    def parse_out_extra_fields(extra_fields_str); end

    # Rubocop: convention: Missing top-level class documentation comment.
    class StoredReader
      # sord omit - no YARD type given for "from_io", using untyped
      # sord omit - no YARD type given for "compressed_data_size", using untyped
      sig { params(from_io: T.untyped, compressed_data_size: T.untyped).void }
      def initialize(from_io, compressed_data_size); end

      # sord omit - no YARD type given for "n_bytes", using untyped
      # sord omit - no YARD return type given, using untyped
      sig { params(n_bytes: T.untyped).returns(T.untyped) }
      def extract(n_bytes = nil); end

      sig { returns(T::Boolean) }
      def eof?; end
    end

    # Rubocop: convention: Missing top-level class documentation comment.
    class InflatingReader
      # sord omit - no YARD type given for "from_io", using untyped
      # sord omit - no YARD type given for "compressed_data_size", using untyped
      sig { params(from_io: T.untyped, compressed_data_size: T.untyped).void }
      def initialize(from_io, compressed_data_size); end

      # sord omit - no YARD type given for "n_bytes", using untyped
      # sord omit - no YARD return type given, using untyped
      sig { params(n_bytes: T.untyped).returns(T.untyped) }
      def extract(n_bytes = nil); end

      sig { returns(T::Boolean) }
      def eof?; end
    end

    # Represents a file within the ZIP archive being read. This is different from
    # the Entry object used in Streamer for ZIP writing, since during writing more
    # data can be kept in memory for immediate use.
    class ZipEntry
      # sord omit - no YARD type given for "from_io", using untyped
      # Returns a reader for the actual compressed data of the entry.
      # 
      #   reader = entry.extractor_from(source_file)
      #   outfile << reader.extract(512 * 1024) until reader.eof?
      # 
      # _@return_ — the reader for the data
      sig { params(from_io: T.untyped).returns(T.any(StoredReader, InflatingReader)) }
      def extractor_from(from_io); end

      # _@return_ — at what offset you should start reading
      # for the compressed data in your original IO object
      sig { returns(Fixnum) }
      def compressed_data_offset; end

      # Tells whether the compressed data offset is already known for this entry
      sig { returns(T::Boolean) }
      def known_offset?; end

      # Tells whether the entry uses a data descriptor (this is defined
      # by bit 3 in the GP flags).
      sig { returns(T::Boolean) }
      def uses_data_descriptor?; end

      # sord infer - inferred type of parameter "offset" as Fixnum using getter's return type
      # sord omit - no YARD return type given, using untyped
      # Sets the offset at which the compressed data for this file starts in the ZIP.
      # By default, the value will be set by the Reader for you. If you use delayed
      # reading, you need to set it by using the `get_compressed_data_offset` on the Reader:
      # 
      #     entry.compressed_data_offset = reader.get_compressed_data_offset(io: file,
      #            local_file_header_offset: entry.local_header_offset)
      sig { params(offset: Fixnum).returns(T.untyped) }
      def compressed_data_offset=(offset); end

      # _@return_ — bit-packed version signature of the program that made the archive
      sig { returns(Fixnum) }
      attr_accessor :made_by

      # _@return_ — ZIP version support needed to extract this file
      sig { returns(Fixnum) }
      attr_accessor :version_needed_to_extract

      # _@return_ — bit-packed general purpose flags
      sig { returns(Fixnum) }
      attr_accessor :gp_flags

      # _@return_ — Storage mode (0 for stored, 8 for deflate)
      sig { returns(Fixnum) }
      attr_accessor :storage_mode

      # _@return_ — the bit-packed DOS time
      sig { returns(Fixnum) }
      attr_accessor :dos_time

      # _@return_ — the bit-packed DOS date
      sig { returns(Fixnum) }
      attr_accessor :dos_date

      # _@return_ — the CRC32 checksum of this file
      sig { returns(Fixnum) }
      attr_accessor :crc32

      # _@return_ — size of compressed file data in the ZIP
      sig { returns(Fixnum) }
      attr_accessor :compressed_size

      # _@return_ — size of the file once uncompressed
      sig { returns(Fixnum) }
      attr_accessor :uncompressed_size

      # _@return_ — the filename
      sig { returns(String) }
      attr_accessor :filename

      # _@return_ — disk number where this file starts
      sig { returns(Fixnum) }
      attr_accessor :disk_number_start

      # _@return_ — internal attributes of the file
      sig { returns(Fixnum) }
      attr_accessor :internal_attrs

      # _@return_ — external attributes of the file
      sig { returns(Fixnum) }
      attr_accessor :external_attrs

      # _@return_ — at what offset the local file header starts
      # in your original IO object
      sig { returns(Fixnum) }
      attr_accessor :local_file_header_offset

      # _@return_ — the file comment
      sig { returns(String) }
      attr_accessor :comment
    end
  end

  # Used when you need to supply a destination IO for some
  # write operations, but want to discard the data (like when
  # estimating the size of a ZIP)
  module NullWriter
    # _@param_ `_` — the data to write
    sig { params(_: String).returns(T.self_type) }
    def self.<<(_); end
  end

  # Alows reading the central directory of a remote ZIP file without
  # downloading the entire file. The central directory provides the
  # offsets at which the actual file contents is located. You can then
  # use the `Range:` HTTP headers to download those entries separately.
  # 
  # Please read the security warning in `FileReader` _VERY CAREFULLY_
  # before you use this module.
  module RemoteUncap
    # {ZipKit::FileReader} when reading
    # files within the remote archive
    # 
    # _@param_ `uri` — the HTTP(S) URL to read the ZIP footer from
    # 
    # _@param_ `reader_class` — which class to use for reading
    # 
    # _@param_ `options_for_zip_reader` — any additional options to give to
    # 
    # _@return_ — metadata about the
    sig { params(uri: String, reader_class: Class, options_for_zip_reader: T::Hash[T.untyped, T.untyped]).returns(T::Array[ZipKit::FileReader::ZipEntry]) }
    def self.files_within_zip_at(uri, reader_class: ZipKit::FileReader, **options_for_zip_reader); end
  end

  # A simple stateful class for keeping track of a CRC32 value through multiple writes
  class StreamCRC32
    include ZipKit::WriteShovel
    STRINGS_HAVE_CAPACITY_SUPPORT = T.let(begin
  String.new("", capacity: 1)
  true
rescue ArgumentError
  false
end, T.untyped)
    CRC_BUF_SIZE = T.let(1024 * 512, T.untyped)

    # Compute a CRC32 value from an IO object. The object should respond to `read` and `eof?`
    # 
    # _@param_ `io` — the IO to read the data from
    # 
    # _@return_ — the computed CRC32 value
    sig { params(io: IO).returns(Fixnum) }
    def self.from_io(io); end

    # Creates a new streaming CRC32 calculator
    sig { void }
    def initialize; end

    # Append data to the CRC32. Updates the contained CRC32 value in place.
    # 
    # _@param_ `blob` — the string to compute the CRC32 from
    sig { params(blob: String).returns(T.self_type) }
    def <<(blob); end

    # Returns the CRC32 value computed so far
    # 
    # _@return_ — the updated CRC32 value for all the blobs so far
    sig { returns(Fixnum) }
    def to_i; end

    # Appends a known CRC32 value to the current one, and combines the
    # contained CRC32 value in-place.
    # 
    # _@param_ `crc32` — the CRC32 value to append
    # 
    # _@param_ `blob_size` — the size of the daata the `crc32` is computed from
    # 
    # _@return_ — the updated CRC32 value for all the blobs so far
    sig { params(crc32: Fixnum, blob_size: Fixnum).returns(Fixnum) }
    def append(crc32, blob_size); end

    # sord infer - argument name in single @param inferred as "bytes"
    # Writes the given data to the output stream. Allows the object to be used as
    # a target for `IO.copy_stream(from, to)`
    # 
    # _@param_ `d` — the binary string to write (part of the uncompressed file)
    # 
    # _@return_ — the number of bytes written
    sig { params(bytes: String).returns(Fixnum) }
    def write(bytes); end
  end

  # Some operations (such as CRC32) benefit when they are performed
  # on larger chunks of data. In certain use cases, it is possible that
  # the consumer of ZipKit is going to be writing small chunks
  # in rapid succession, so CRC32 is going to have to perform a lot of
  # CRC32 combine operations - and this adds up. Since the CRC32 value
  # is usually not needed until the complete output has completed
  # we can buffer at least some amount of data before computing CRC32 over it.
  # We also use this buffer for output via Rack, where some amount of buffering
  # helps reduce the number of syscalls made by the webserver. ZipKit performs
  # lots of very small writes, and some degree of speedup (about 20%) can be achieved
  # with a buffer of a few KB.
  # 
  # Note that there is no guarantee that the write buffer is going to flush at or above
  # the given `buffer_size`, because for writes which exceed the buffer size it will
  # first `flush` and then write through the oversized chunk, without buffering it. This
  # helps conserve memory. Also note that the buffer will *not* duplicate strings for you
  # and *will* yield the same buffer String over and over, so if you are storing it in an
  # Array you might need to duplicate it.
  # 
  # Note also that the WriteBuffer assumes that the object it `<<`-writes into is going
  # to **consume** in some way the string that it passes in. After the `<<` method returns,
  # the WriteBuffer will be cleared, and it passes the same String reference on every call
  # to `<<`. Therefore, if you need to retain the output of the WriteBuffer in, say, an Array,
  # you might need to `.dup` the `String` it gives you.
  class WriteBuffer
    # sord duck - #<< looks like a duck type, replacing with untyped
    # Creates a new WriteBuffer bypassing into a given writable object
    # 
    # _@param_ `writable` — An object that responds to `#<<` with a String as argument
    # 
    # _@param_ `buffer_size` — How many bytes to buffer
    sig { params(writable: T.untyped, buffer_size: Integer).void }
    def initialize(writable, buffer_size); end

    # Appends the given data to the write buffer, and flushes the buffer into the
    # writable if the buffer size exceeds the `buffer_size` given at initialization
    # 
    # _@param_ `data` — data to be written
    # 
    # _@return_ — self
    sig { params(data: String).returns(T.untyped) }
    def <<(data); end

    # Explicitly flushes the buffer if it contains anything
    # 
    # _@return_ — self
    sig { returns(T.untyped) }
    def flush; end
  end

  # A lot of objects in ZipKit accept bytes that may be sent
  # to the `<<` operator (the "shovel" operator). This is in the tradition
  # of late Jim Weirich and his Builder gem. In [this presentation](https://youtu.be/1BVFlvRPZVM?t=2403)
  # he justifies this design very eloquently. In ZipKit we follow this example.
  # However, there is a number of methods in Ruby - including the standard library -
  # which expect your object to implement the `write` method instead. Since the `write`
  # method can be expressed in terms of the `<<` method, why not allow all ZipKit
  # "IO-ish" things to also respond to `write`? This is what this module does.
  # Jim would be proud. We miss you, Jim.
  module WriteShovel
    # sord infer - argument name in single @param inferred as "bytes"
    # Writes the given data to the output stream. Allows the object to be used as
    # a target for `IO.copy_stream(from, to)`
    # 
    # _@param_ `d` — the binary string to write (part of the uncompressed file)
    # 
    # _@return_ — the number of bytes written
    sig { params(bytes: String).returns(Fixnum) }
    def write(bytes); end
  end

  # Permits Deflate compression in independent blocks. The workflow is as follows:
  # 
  # * Run every block to compress through deflate_chunk, remove the header,
  #   footer and adler32 from the result
  # * Write out the compressed block bodies (the ones deflate_chunk returns)
  #   to your output, in sequence
  # * Write out the footer (\03\00)
  # 
  # The resulting stream is guaranteed to be handled properly by all zip
  # unarchiving tools, including the BOMArchiveHelper/ArchiveUtility on OSX.
  # 
  # You could also build a compressor for Rubyzip using this module quite easily,
  # even though this is outside the scope of the library.
  # 
  # When you deflate the chunks separately, you need to write the end marker
  # yourself (using `write_terminator`).
  # If you just want to deflate a large IO's contents, use
  # `deflate_in_blocks_and_terminate` to have the end marker written out for you.
  # 
  # Basic usage to compress a file in parts:
  # 
  #     source_file = File.open('12_gigs.bin', 'rb')
  #     compressed = Tempfile.new
  #     # Will not compress everything in memory, but do it per chunk to spare
  #       memory. `compressed`
  #     # will be written to at the end of each chunk.
  #     ZipKit::BlockDeflate.deflate_in_blocks_and_terminate(source_file,
  #                                                             compressed)
  # 
  # You can also do the same to parts that you will later concatenate together
  # elsewhere, in that case you need to skip the end marker:
  # 
  #     compressed = Tempfile.new
  #     ZipKit::BlockDeflate.deflate_in_blocks(File.open('part1.bin', 'rb),
  #                                               compressed)
  #     ZipKit::BlockDeflate.deflate_in_blocks(File.open('part2.bin', 'rb),
  #                                               compressed)
  #     ZipKit::BlockDeflate.deflate_in_blocks(File.open('partN.bin', 'rb),
  #                                               compressed)
  #     ZipKit::BlockDeflate.write_terminator(compressed)
  # 
  # You can also elect to just compress strings in memory (to splice them later):
  # 
  #     compressed_string = ZipKit::BlockDeflate.deflate_chunk(big_string)
  class BlockDeflate
    DEFAULT_BLOCKSIZE = T.let(1_024 * 1024 * 5, T.untyped)
    END_MARKER = T.let([3, 0].pack("C*"), T.untyped)
    VALID_COMPRESSIONS = T.let((Zlib::DEFAULT_COMPRESSION..Zlib::BEST_COMPRESSION).to_a.freeze, T.untyped)

    # Write the end marker (\x3\x0) to the given IO.
    # 
    # `output_io` can also be a {ZipKit::Streamer} to expedite ops.
    # 
    # _@param_ `output_io` — the stream to write to (should respond to `:<<`)
    # 
    # _@return_ — number of bytes written to `output_io`
    sig { params(output_io: IO).returns(Fixnum) }
    def self.write_terminator(output_io); end

    # Compress a given binary string and flush the deflate stream at byte boundary.
    # The returned string can be spliced into another deflate stream.
    # 
    # _@param_ `bytes` — Bytes to compress
    # 
    # _@param_ `level` — Zlib compression level (defaults to `Zlib::DEFAULT_COMPRESSION`)
    # 
    # _@return_ — compressed bytes
    sig { params(bytes: String, level: Fixnum).returns(String) }
    def self.deflate_chunk(bytes, level: Zlib::DEFAULT_COMPRESSION); end

    # Compress the contents of input_io into output_io, in blocks
    # of block_size. Aligns the parts so that they can be concatenated later.
    # Writes deflate end marker (\x3\x0) into `output_io` as the final step, so
    # the contents of `output_io` can be spliced verbatim into a ZIP archive.
    # 
    # Once the write completes, no more parts for concatenation should be written to
    # the same stream.
    # 
    # `output_io` can also be a {ZipKit::Streamer} to expedite ops.
    # 
    # _@param_ `input_io` — the stream to read from (should respond to `:read`)
    # 
    # _@param_ `output_io` — the stream to write to (should respond to `:<<`)
    # 
    # _@param_ `level` — Zlib compression level (defaults to `Zlib::DEFAULT_COMPRESSION`)
    # 
    # _@param_ `block_size` — The block size to use (defaults to `DEFAULT_BLOCKSIZE`)
    # 
    # _@return_ — number of bytes written to `output_io`
    sig do
      params(
        input_io: IO,
        output_io: IO,
        level: Fixnum,
        block_size: Fixnum
      ).returns(Fixnum)
    end
    def self.deflate_in_blocks_and_terminate(input_io, output_io, level: Zlib::DEFAULT_COMPRESSION, block_size: DEFAULT_BLOCKSIZE); end

    # Compress the contents of input_io into output_io, in blocks
    # of block_size. Align the parts so that they can be concatenated later.
    # Will not write the deflate end marker (\x3\x0) so more parts can be written
    # later and succesfully read back in provided the end marker wll be written.
    # 
    # `output_io` can also be a {ZipKit::Streamer} to expedite ops.
    # 
    # _@param_ `input_io` — the stream to read from (should respond to `:read`)
    # 
    # _@param_ `output_io` — the stream to write to (should respond to `:<<`)
    # 
    # _@param_ `level` — Zlib compression level (defaults to `Zlib::DEFAULT_COMPRESSION`)
    # 
    # _@param_ `block_size` — The block size to use (defaults to `DEFAULT_BLOCKSIZE`)
    # 
    # _@return_ — number of bytes written to `output_io`
    sig do
      params(
        input_io: IO,
        output_io: IO,
        level: Fixnum,
        block_size: Fixnum
      ).returns(Fixnum)
    end
    def self.deflate_in_blocks(input_io, output_io, level: Zlib::DEFAULT_COMPRESSION, block_size: DEFAULT_BLOCKSIZE); end
  end

  # Helps to estimate archive sizes
  class SizeEstimator
    # Creates a new estimator with a Streamer object. Normally you should use
    # `estimate` instead an not use this method directly.
    # 
    # _@param_ `streamer`
    sig { params(streamer: ZipKit::Streamer).void }
    def initialize(streamer); end

    # Performs the estimate using fake archiving. It needs to know the sizes of the
    # entries upfront. Usage:
    # 
    #     expected_zip_size = SizeEstimator.estimate do | estimator |
    #       estimator.add_stored_entry(filename: "file.doc", size: 898291)
    #       estimator.add_deflated_entry(filename: "family.tif",
    #               uncompressed_size: 89281911, compressed_size: 121908)
    #     end
    # 
    # _@param_ `kwargs_for_streamer_new` — Any options to pass to Streamer, see {Streamer#initialize}
    # 
    # _@return_ — the size of the resulting archive, in bytes
    sig { params(kwargs_for_streamer_new: T.untyped, blk: T.proc.params(the: SizeEstimator).void).returns(Integer) }
    def self.estimate(**kwargs_for_streamer_new, &blk); end

    # Add a fake entry to the archive, to see how big it is going to be in the end.
    # 
    # data descriptor to specify size
    # 
    # _@param_ `filename` — the name of the file (filenames are variable-width in the ZIP)
    # 
    # _@param_ `size` — size of the uncompressed entry
    # 
    # _@param_ `use_data_descriptor` — whether the entry uses a postfix
    # 
    # _@return_ — self
    sig { params(filename: String, size: Fixnum, use_data_descriptor: T::Boolean).returns(T.untyped) }
    def add_stored_entry(filename:, size:, use_data_descriptor: false); end

    # Add a fake entry to the archive, to see how big it is going to be in the end.
    # 
    # _@param_ `filename` — the name of the file (filenames are variable-width in the ZIP)
    # 
    # _@param_ `uncompressed_size` — size of the uncompressed entry
    # 
    # _@param_ `compressed_size` — size of the compressed entry
    # 
    # _@param_ `use_data_descriptor` — whether the entry uses a postfix data descriptor to specify size
    # 
    # _@return_ — self
    sig do
      params(
        filename: String,
        uncompressed_size: Fixnum,
        compressed_size: Fixnum,
        use_data_descriptor: T::Boolean
      ).returns(T.untyped)
    end
    def add_deflated_entry(filename:, uncompressed_size:, compressed_size:, use_data_descriptor: false); end

    # Add an empty directory to the archive.
    # 
    # _@param_ `dirname` — the name of the directory
    # 
    # _@return_ — self
    sig { params(dirname: String).returns(T.untyped) }
    def add_empty_directory_entry(dirname:); end
  end

  # A tiny wrapper over any object that supports :<<.
  # Adds :tell and :advance_position_by. This is needed for write destinations
  # which do not respond to `#pos` or `#tell`. A lot of ZIP archive format parts
  # include "offsets in archive" - a byte offset from the start of file. Keeping
  # track of this value is what this object will do. It also allows "advancing"
  # this value if data gets written using a bypass (such as `IO#sendfile`)
  class WriteAndTell
    include ZipKit::WriteShovel

    # sord omit - no YARD type given for "io", using untyped
    sig { params(io: T.untyped).void }
    def initialize(io); end

    # sord omit - no YARD type given for "bytes", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(bytes: T.untyped).returns(T.untyped) }
    def <<(bytes); end

    # sord omit - no YARD type given for "num_bytes", using untyped
    # sord omit - no YARD return type given, using untyped
    sig { params(num_bytes: T.untyped).returns(T.untyped) }
    def advance_position_by(num_bytes); end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def tell; end

    # sord infer - argument name in single @param inferred as "bytes"
    # Writes the given data to the output stream. Allows the object to be used as
    # a target for `IO.copy_stream(from, to)`
    # 
    # _@param_ `d` — the binary string to write (part of the uncompressed file)
    # 
    # _@return_ — the number of bytes written
    sig { params(bytes: String).returns(Fixnum) }
    def write(bytes); end
  end

  # Should be included into a Rails controller for easy ZIP output from any action.
  module RailsStreaming
    # Opens a {ZipKit::Streamer} and yields it to the caller. The output of the streamer
    # gets automatically forwarded to the Rails response stream. When the output completes,
    # the Rails response stream is going to be closed automatically.
    # 
    # _@param_ `filename` — name of the file for the Content-Disposition header
    # 
    # _@param_ `type` — the content type (MIME type) of the archive being output
    # 
    # _@param_ `use_chunked_transfer_encoding` — whether to forcibly encode output as chunked. Normally you should not need this.
    # 
    # _@param_ `zip_streamer_options` — options that will be passed to the Streamer. See {ZipKit::Streamer#initialize} for the full list of options.
    # 
    # _@return_ — The output enumerator assigned to the response body
    sig do
      params(
        filename: String,
        type: String,
        use_chunked_transfer_encoding: T::Boolean,
        zip_streamer_options: T::Hash[T.untyped, T.untyped],
        zip_streaming_blk: T.proc.params(the: ZipKit::Streamer).void
      ).returns(ZipKit::OutputEnumerator)
    end
    def zip_kit_stream(filename: "download.zip", type: "application/zip", use_chunked_transfer_encoding: false, **zip_streamer_options, &zip_streaming_blk); end
  end

  # The output enumerator makes it possible to "pull" from a ZipKit streamer
  # object instead of having it "push" writes to you. It will "stash" the block which
  # writes the ZIP archive through the streamer, and when you call `each` on the Enumerator
  # it will yield you the bytes the block writes. Since it is an enumerator you can
  # use `next` to take chunks written by the ZipKit streamer one by one. It can be very
  # convenient when you need to segment your ZIP output into bigger chunks for, say,
  # uploading them to a cloud storage provider such as S3.
  # 
  # Another use of the `OutputEnumerator` is as a Rack response body - since a Rack
  # response body object must support `#each` yielding successive binary strings.
  # Which is exactly what `OutputEnumerator` does.
  # 
  # The enumerator can provide you some more conveinences for HTTP output - correct streaming
  # headers and a body with chunked transfer encoding.
  # 
  #     iterable_zip_body = ZipKit::OutputEnumerator.new do | streamer |
  #       streamer.write_file('big.csv') do |sink|
  #         CSV(sink) do |csv_writer|
  #           csv_writer << Person.column_names
  #           Person.all.find_each do |person|
  #             csv_writer << person.attributes.values
  #           end
  #         end
  #       end
  #     end
  # 
  # You can grab the headers one usually needs for streaming from `#streaming_http_headers`:
  # 
  #     [200, iterable_zip_body.streaming_http_headers, iterable_zip_body]
  # 
  # to bypass things like `Rack::ETag` and the nginx buffering.
  class OutputEnumerator
    DEFAULT_WRITE_BUFFER_SIZE = T.let(64 * 1024, T.untyped)

    # Creates a new OutputEnumerator enumerator. The enumerator can be read from using `each`,
    # and the creation of the ZIP is in lockstep with the caller calling `each` on the returned
    # output enumerator object. This can be used when the calling program wants to stream the
    # output of the ZIP archive and throttle that output, or split it into chunks, or use it
    # as a generator.
    # 
    # For example:
    # 
    #     # The block given to {output_enum} won't be executed immediately - rather it
    #     # will only start to execute when the caller starts to read from the output
    #     # by calling `each`
    #     body = ::ZipKit::OutputEnumerator.new(writer: CustomWriter) do |streamer|
    #       streamer.add_stored_entry(filename: 'large.tif', size: 1289894, crc32: 198210)
    #       streamer << large_file.read(1024*1024) until large_file.eof?
    #       ...
    #     end
    # 
    #     body.each do |bin_string|
    #       # Send the output somewhere, buffer it in a file etc.
    #       # The block passed into `initialize` will only start executing once `#each`
    #       # is called
    #       ...
    #     end
    # 
    # _@param_ `kwargs_for_new` — keyword arguments for {Streamer.new}
    # 
    # _@param_ `streamer_options` — options for Streamer, see {ZipKit::Streamer.new}
    # 
    # _@param_ `write_buffer_size` — By default all ZipKit writes are unbuffered. For output to sockets it is beneficial to bulkify those writes so that they are roughly sized to a socket buffer chunk. This object will bulkify writes for you in this way (so `each` will yield not on every call to `<<` from the Streamer but at block size boundaries or greater). Set it to 0 for unbuffered writes.
    # 
    # _@param_ `blk` — a block that will receive the Streamer object when executing. The block will not be executed immediately but only once `each` is called on the OutputEnumerator
    # 
    # _@return_ — the enumerator you can read bytestrings of the ZIP from by calling `each`
    sig { params(write_buffer_size: Integer, streamer_options: T::Hash[T.untyped, T.untyped], blk: T.untyped).void }
    def initialize(write_buffer_size: DEFAULT_WRITE_BUFFER_SIZE, **streamer_options, &blk); end

    # sord omit - no YARD return type given, using untyped
    # Executes the block given to the constructor with a {ZipKit::Streamer}
    # and passes each written chunk to the block given to the method. This allows one
    # to "take" output of the ZIP piecewise. If called without a block will return an Enumerator
    # that you can pull data from using `next`.
    # 
    # **NOTE** Because the `WriteBuffer` inside this object can reuse the buffer, it is important
    #    that the `String` that is yielded **either** gets consumed eagerly (written byte-by-byte somewhere, or `#dup`-ed)
    #    since the write buffer will clear it after your block returns. If you expand this Enumerator
    #    eagerly into an Array you might notice that a lot of the segments of your ZIP output are
    #    empty - this means that you need to duplicate them.
    sig { returns(T.untyped) }
    def each; end

    # Returns a Hash of HTTP response headers you are likely to need to have your response stream correctly.
    sig { returns(T::Hash[T.untyped, T.untyped]) }
    def streaming_http_headers; end

    # Returns a tuple of `headers, body` - headers are a `Hash` and the body is
    # an object that can be used as a Rack response body. This method used to accept arguments
    # but will now just ignore them.
    sig { returns(T::Array[T.untyped]) }
    def to_headers_and_rack_response_body; end
  end

  # A body wrapper that emits chunked responses, creating valid
  # Transfer-Encoding::Chunked HTTP response body. This is copied from Rack::Chunked::Body,
  # because Rack is not going to include that class after version 3.x
  # Rails has a substitute class for this inside ActionController::Streaming,
  # but that module is a private constant in the Rails codebase, and is thus
  # considered "private" from the Rails standpoint. It is not that much code to
  # carry, so we copy it into our code.
  class RackChunkedBody
    TERM = T.let("\r\n", T.untyped)
    TAIL = T.let("0#{TERM}", T.untyped)

    # sord duck - #each looks like a duck type, replacing with untyped
    # _@param_ `body` — the enumerable that yields bytes, usually a `OutputEnumerator`
    sig { params(body: T.untyped).void }
    def initialize(body); end

    # sord omit - no YARD return type given, using untyped
    # For each string yielded by the response body, yield
    # the element in chunked encoding - and finish off with a terminator
    sig { returns(T.untyped) }
    def each; end
  end

  module UniquifyFilename
    # sord duck - #include? looks like a duck type, replacing with untyped
    # Makes a given filename unique by appending a (n) suffix
    # between just before the filename extension. So "file.txt" gets
    # transformed into "file (1).txt". The transformation is applied
    # repeatedly as long as the generated filename is present
    # in `while_included_in` object
    # 
    # _@param_ `path` — the path to make unique
    # 
    # _@param_ `while_included_in` — an object that stores the list of already used paths
    # 
    # _@return_ — the path as is, or with the suffix required to make it unique
    sig { params(path: String, while_included_in: T.untyped).returns(String) }
    def self.call(path, while_included_in); end
  end

  # Contains a file handle which can be closed once the response finishes sending.
  # It supports `to_path` so that `Rack::Sendfile` can intercept it.
  # This class is deprecated and is going to be removed in zip_kit 7.x
  # @api deprecated
  class RackTempfileBody
    TEMPFILE_NAME_PREFIX = T.let("zip-tricks-tf-body-", T.untyped)

    # sord omit - no YARD type given for "env", using untyped
    # sord duck - #each looks like a duck type, replacing with untyped
    # _@param_ `body` — the enumerable that yields bytes, usually a `OutputEnumerator`. The `body` will be read in full immediately and closed.
    sig { params(env: T.untyped, body: T.untyped).void }
    def initialize(env, body); end

    # Returns the size of the contained `Tempfile` so that a correct
    # Content-Length header can be set
    sig { returns(Integer) }
    def size; end

    # Returns the path to the `Tempfile`, so that Rack::Sendfile can send this response
    # using the downstream webserver
    sig { returns(String) }
    def to_path; end

    # Stream the file's contents if `Rack::Sendfile` isn't present.
    sig { void }
    def each; end

    # sord omit - no YARD return type given, using untyped
    sig { returns(T.untyped) }
    def flush; end

    # sord omit - no YARD type given for :tempfile, using untyped
    sig { returns(T.untyped) }
    attr_reader :tempfile
  end
end
