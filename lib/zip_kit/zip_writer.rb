# frozen_string_literal: true

require "stringio"

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
class ZipKit::ZipWriter
  FOUR_BYTE_MAX_UINT = 0xFFFFFFFF
  TWO_BYTE_MAX_UINT = 0xFFFF
  ZIP_KIT_COMMENT = ("Written using ZipKit %<version>s" % {version: ZipKit::VERSION}).freeze
  VERSION_MADE_BY = 52
  VERSION_NEEDED_TO_EXTRACT = 20
  VERSION_NEEDED_TO_EXTRACT_ZIP64 = 45
  DEFAULT_FILE_UNIX_PERMISSIONS = 0o644
  DEFAULT_DIRECTORY_UNIX_PERMISSIONS = 0o755
  FILE_TYPE_FILE = 0o10
  FILE_TYPE_DIRECTORY = 0o04
  MADE_BY_SIGNATURE = begin
    # A combination of the VERSION_MADE_BY low byte and the OS type high byte
    os_type = 3 # UNIX
    [VERSION_MADE_BY, os_type].pack("CC").freeze
  end

  # Every record gets packed in one go, since packing value-by-value allocates an Array and a String
  # per value. "V" is a 4-byte and "v" a 2-byte unsigned little-endian uint, "Q<" is an 8-byte one,
  # "a2" is a 2-byte binary string and "a*" appends the bytes of a String regardless of its encoding.
  LOCAL_FILE_HEADER_PACKSPEC = "VvvvvvVVVvva*a*"
  CENTRAL_DIRECTORY_FILE_HEADER_PACKSPEC = "Va2vvvvvVVVvvvvvVVa*a*"
  DATA_DESCRIPTOR_PACKSPEC = "VVVV"
  DATA_DESCRIPTOR_ZIP64_PACKSPEC = "VVQ<Q<"
  ZIP64_END_OF_CENTRAL_DIRECTORY_PACKSPEC = "VQ<a2vVVQ<Q<Q<Q<VVQ<V"
  END_OF_CENTRAL_DIRECTORY_PACKSPEC = "VvvvvVVva*"
  ZIP64_EXTRA_FOR_LOCAL_FILE_HEADER_PACKSPEC = "vvQ<Q<"
  ZIP64_EXTRA_FOR_CENTRAL_DIRECTORY_FILE_HEADER_PACKSPEC = "vvQ<Q<Q<V"
  TIMESTAMP_EXTRA_PACKSPEC = "vvCl<" # the mtime is a signed int, unlike the rest of the ZIP spec

  private_constant :FOUR_BYTE_MAX_UINT,
    :TWO_BYTE_MAX_UINT,
    :VERSION_MADE_BY,
    :VERSION_NEEDED_TO_EXTRACT,
    :VERSION_NEEDED_TO_EXTRACT_ZIP64,
    :FILE_TYPE_FILE,
    :FILE_TYPE_DIRECTORY,
    :MADE_BY_SIGNATURE,
    :LOCAL_FILE_HEADER_PACKSPEC,
    :CENTRAL_DIRECTORY_FILE_HEADER_PACKSPEC,
    :DATA_DESCRIPTOR_PACKSPEC,
    :DATA_DESCRIPTOR_ZIP64_PACKSPEC,
    :ZIP64_END_OF_CENTRAL_DIRECTORY_PACKSPEC,
    :END_OF_CENTRAL_DIRECTORY_PACKSPEC,
    :ZIP64_EXTRA_FOR_LOCAL_FILE_HEADER_PACKSPEC,
    :ZIP64_EXTRA_FOR_CENTRAL_DIRECTORY_FILE_HEADER_PACKSPEC,
    :TIMESTAMP_EXTRA_PACKSPEC,
    :ZIP_KIT_COMMENT

  # Writes the local file header, that precedes the actual file _data_.
  #
  # @param io[#<<] the buffer to write the local file header to
  # @param filename[String]  the name of the file in the archive
  # @param compressed_size[Integer]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Integer]  The size of the file once extracted
  # @param crc32[Integer] The CRC32 checksum of the file
  # @param mtime[Time]  the modification time to be recorded in the ZIP
  # @param gp_flags[Integer] bit-packed general purpose flags
  # @param storage_mode[Integer] 8 for deflated, 0 for stored...
  # @return [void]
  def write_local_file_header(io:, filename:, compressed_size:, uncompressed_size:, crc32:, gp_flags:, mtime:, storage_mode:)
    requires_zip64 = compressed_size > FOUR_BYTE_MAX_UINT || uncompressed_size > FOUR_BYTE_MAX_UINT

    # Interesting tidbit:
    # https://social.technet.microsoft.com/Forums/windows/en-US/6a60399f-2879-4859-b7ab-6ddd08a70948
    # TL;DR of it is: Windows 7 Explorer _will_ open Zip64 entries. However, it desires to have the
    # Zip64 extra field as _the first_ extra field.
    extra_fields = timestamp_extra_for_local_file_header(mtime)
    if requires_zip64
      extra_fields = zip_64_extra_for_local_file_header(compressed_size: compressed_size, uncompressed_size: uncompressed_size) + extra_fields
    end

    io << [
      # local file header signature     4 bytes  (0x04034b50)
      0x04034b50,
      # version needed to extract       2 bytes
      requires_zip64 ? VERSION_NEEDED_TO_EXTRACT_ZIP64 : VERSION_NEEDED_TO_EXTRACT,
      # general purpose bit flag        2 bytes
      gp_flags,
      # compression method              2 bytes
      storage_mode,
      # last mod file time              2 bytes
      to_binary_dos_time(mtime),
      # last mod file date              2 bytes
      to_binary_dos_date(mtime),
      # crc-32                          4 bytes
      crc32,
      # compressed size                 4 bytes
      requires_zip64 ? FOUR_BYTE_MAX_UINT : compressed_size,
      # uncompressed size               4 bytes
      requires_zip64 ? FOUR_BYTE_MAX_UINT : uncompressed_size,
      # Filename should not be longer than 0xFFFF otherwise this wont fit here
      # file name length                2 bytes
      filename.bytesize,
      # extra field length              2 bytes
      extra_fields.bytesize,
      # file name (variable size)
      filename,
      # Contents of the extra fields (variable size)
      extra_fields
    ].pack(LOCAL_FILE_HEADER_PACKSPEC)
  end

  # Writes the file header for the central directory, for a particular file in the archive. When writing out this data,
  # ensure that the CRC32 and both sizes (compressed/uncompressed) are correct for the entry in question.
  #
  # @param io[#<<] the buffer to write the local file header to
  # @param filename[String]  the name of the file in the archive
  # @param compressed_size[Integer]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Integer]  The size of the file once extracted
  # @param crc32[Integer] The CRC32 checksum of the file
  # @param mtime[Time]  the modification time to be recorded in the ZIP
  # @param gp_flags[Integer] bit-packed general purpose flags
  # @param unix_permissions[Integer] the permissions for the file, or nil for the default to be used
  # @return [void]
  def write_central_directory_file_header(io:,
    local_file_header_location:,
    gp_flags:,
    storage_mode:,
    compressed_size:,
    uncompressed_size:,
    mtime:,
    crc32:,
    filename:,
    unix_permissions: nil)
    # At this point if the header begins somewhere beyound 0xFFFFFFFF we _have_ to record the offset
    # of the local file header as a zip64 extra field, so we give up, give in, you loose, love will always win...
    add_zip64 = (local_file_header_location > FOUR_BYTE_MAX_UINT) ||
      (compressed_size > FOUR_BYTE_MAX_UINT) || (uncompressed_size > FOUR_BYTE_MAX_UINT)

    extra_fields = timestamp_extra_for_central_directory_entry(mtime)
    if add_zip64
      extra_fields = zip_64_extra_for_central_directory_file_header(local_file_header_location: local_file_header_location,
        compressed_size: compressed_size,
        uncompressed_size: uncompressed_size) + extra_fields
    end

    # Because the add_empty_directory method will create a directory with a trailing "/",
    # this check can be used to assign proper permissions to the created directory.
    external_attrs = if filename.end_with?("/")
      unix_permissions ||= DEFAULT_DIRECTORY_UNIX_PERMISSIONS
      generate_external_attrs(unix_permissions, FILE_TYPE_DIRECTORY)
    else
      unix_permissions ||= DEFAULT_FILE_UNIX_PERMISSIONS
      generate_external_attrs(unix_permissions, FILE_TYPE_FILE)
    end

    io << [
      # central file header signature   4 bytes  (0x02014b50)
      0x02014b50,
      # version made by                 2 bytes
      MADE_BY_SIGNATURE,
      # version needed to extract       2 bytes
      add_zip64 ? VERSION_NEEDED_TO_EXTRACT_ZIP64 : VERSION_NEEDED_TO_EXTRACT,
      # general purpose bit flag        2 bytes
      gp_flags,
      # compression method              2 bytes
      storage_mode,
      # last mod file time              2 bytes
      to_binary_dos_time(mtime),
      # last mod file date              2 bytes
      to_binary_dos_date(mtime),
      # crc-32                          4 bytes
      crc32,
      # compressed size                 4 bytes
      add_zip64 ? FOUR_BYTE_MAX_UINT : compressed_size,
      # uncompressed size               4 bytes
      add_zip64 ? FOUR_BYTE_MAX_UINT : uncompressed_size,
      # Filename should not be longer than 0xFFFF otherwise this wont fit here
      # file name length                2 bytes
      filename.bytesize,
      # extra field length              2 bytes
      extra_fields.bytesize,
      # file comment length             2 bytes
      0,
      # For The Unarchiver < 3.11.1 this field has to be set to the overflow value if zip64 is used
      # because otherwise it does not properly advance the pointer when reading the Zip64 extra field
      # https://bitbucket.org/WAHa_06x36/theunarchiver/pull-requests/2/bug-fix-for-zip64-extra-field-parser/diff
      # disk number start               2 bytes
      add_zip64 ? TWO_BYTE_MAX_UINT : 0,
      # internal file attributes        2 bytes
      0,
      # external file attributes        4 bytes
      external_attrs,
      # relative offset of local header 4 bytes
      add_zip64 ? FOUR_BYTE_MAX_UINT : local_file_header_location,
      # file name (variable size)
      filename,
      # extra field (variable size)
      extra_fields
      # file comment (variable size)
      # (empty)
    ].pack(CENTRAL_DIRECTORY_FILE_HEADER_PACKSPEC)
  end

  # Writes the data descriptor following the file data for a file whose local file header
  # was written with general-purpose flag bit 3 set. If the one of the sizes exceeds the Zip64 threshold,
  # the data descriptor will have the sizes written out as 8-byte values instead of 4-byte values.
  #
  # @param io[#<<] the buffer to write the local file header to
  # @param crc32[Integer]    The CRC32 checksum of the file
  # @param compressed_size[Integer]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Integer]  The size of the file once extracted
  # @return [void]
  def write_data_descriptor(io:, compressed_size:, uncompressed_size:, crc32:)
    # If one of the sizes is above 0xFFFFFFF use ZIP64 lengths (8 bytes) instead. A good unarchiver
    # will decide to unpack it as such if it finds the Zip64 extra for the file in the central directory.
    # So also use the opportune moment to switch the entry to Zip64 if needed.
    # We switch if either of the sizes requires ZIP64, so that both values are encoded similarly.
    requires_zip64 = compressed_size > FOUR_BYTE_MAX_UINT || uncompressed_size > FOUR_BYTE_MAX_UINT

    io << [
      # Although not originally assigned a signature, the value
      # 0x08074b50 has commonly been adopted as a signature value
      # for the data descriptor record.
      0x08074b50,
      # crc-32                          4 bytes
      crc32,
      # compressed size                 4 bytes, or 8 bytes for ZIP64
      compressed_size,
      # uncompressed size               4 bytes, or 8 bytes for ZIP64
      uncompressed_size
    ].pack(requires_zip64 ? DATA_DESCRIPTOR_ZIP64_PACKSPEC : DATA_DESCRIPTOR_PACKSPEC)
  end

  # Writes the "end of central directory record" (including the Zip6 salient bits if necessary)
  #
  # @param io[#<<] the buffer to write the central directory to.
  # @param start_of_central_directory_location[Integer] byte offset of the start of central directory form the beginning of ZIP file
  # @param central_directory_size[Integer] the size of the central directory (only file headers) in bytes
  # @param num_files_in_archive[Integer] How many files the archive contains
  # @param comment[String] the comment for the archive (defaults to ZIP_KIT_COMMENT)
  # @return [void]
  def write_end_of_central_directory(io:, start_of_central_directory_location:, central_directory_size:, num_files_in_archive:, comment: ZIP_KIT_COMMENT)
    zip64_eocdr_offset = start_of_central_directory_location + central_directory_size

    zip64_required = central_directory_size > FOUR_BYTE_MAX_UINT ||
      start_of_central_directory_location > FOUR_BYTE_MAX_UINT ||
      zip64_eocdr_offset > FOUR_BYTE_MAX_UINT ||
      num_files_in_archive > TWO_BYTE_MAX_UINT

    # Then, if zip64 is used
    if zip64_required
      io << [
        # [zip64 end of central directory record]
        # zip64 end of central dir signature                       4 bytes  (0x06064b50)
        0x06064b50,
        # size of zip64 end of central
        # directory record                8 bytes
        # (this is ex. the 12 bytes of the signature and the size value itself).
        # Without the extensible data sector (which we are not using)
        # it is always 44 bytes.
        44,
        # version made by                 2 bytes
        MADE_BY_SIGNATURE,
        # version needed to extract       2 bytes
        VERSION_NEEDED_TO_EXTRACT_ZIP64,
        # number of this disk             4 bytes
        0,
        # number of the disk with the start of the central directory  4 bytes
        0,
        # total number of entries in the
        # central directory on this disk  8 bytes
        num_files_in_archive,
        # total number of entries in the
        # central directory               8 bytes
        num_files_in_archive,
        # size of the central directory   8 bytes
        central_directory_size,
        # offset of start of central directory with respect to
        # the starting disk number        8 bytes
        start_of_central_directory_location,
        # zip64 extensible data sector (variable size)
        # (blank for us)

        # zip64 end of central dir locator
        # signature                       4 bytes  (0x07064b50)
        0x07064b50,
        # number of the disk with the start of the zip64 end of
        # central directory               4 bytes
        0,
        # relative offset of the zip64
        # end of central directory record 8 bytes
        # (note: "relative" is actually "from the start of the file")
        zip64_eocdr_offset,
        # total number of disks           4 bytes
        1
      ].pack(ZIP64_END_OF_CENTRAL_DIRECTORY_PACKSPEC)
    end

    io << [
      # Then the end of central directory record:
      # end of central dir signature     4 bytes  (0x06054b50)
      0x06054b50,
      # number of this disk              2 bytes
      0,
      # number of the disk with the
      # start of the central directory 2 bytes
      0,
      # total number of entries in the
      # central directory on this disk   2 bytes
      # (the number of entries will be read from the zip64 part of the central directory if zip64 is used)
      zip64_required ? TWO_BYTE_MAX_UINT : num_files_in_archive,
      # total number of entries in
      # the central directory            2 bytes
      zip64_required ? TWO_BYTE_MAX_UINT : num_files_in_archive,
      # size of the central directory    4 bytes
      zip64_required ? FOUR_BYTE_MAX_UINT : central_directory_size,
      # offset of start of central
      # directory with respect to
      # the starting disk number        4 bytes
      zip64_required ? FOUR_BYTE_MAX_UINT : start_of_central_directory_location,
      # .ZIP file comment length        2 bytes
      comment.bytesize,
      # .ZIP file comment       (variable size)
      comment
    ].pack(END_OF_CENTRAL_DIRECTORY_PACKSPEC)
  end

  private

  # Writes the Zip64 extra field for the local file header. Will be used by `write_local_file_header` when any sizes given to it warrant that.
  #
  # @param compressed_size[Integer]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Integer]  The size of the file once extracted
  # @return [String]
  def zip_64_extra_for_local_file_header(compressed_size:, uncompressed_size:)
    [
      # 2 bytes    Tag for this "extra" block type
      0x0001,
      # 2 bytes    Size of this "extra" block. For us it will always be 16 (2x8)
      16,
      # 8 bytes    Original uncompressed file size
      uncompressed_size,
      # 8 bytes    Size of compressed data
      compressed_size
    ].pack(ZIP64_EXTRA_FOR_LOCAL_FILE_HEADER_PACKSPEC)
  end

  # Writes the extended timestamp information field for local headers.
  #
  # The spec defines 2
  # different formats - the one for the local file header can also accomodate the
  # atime and ctime, whereas the one for the central directory can only take
  # the mtime - and refers the reader to the local header extra to obtain the
  # remaining times
  def timestamp_extra_for_local_file_header(mtime)
    #         Local-header version:
    #
    #         Value         Size        Description
    #         -----         ----        -----------
    # (time)  0x5455        Short       tag for this extra block type ("UT")
    #         TSize         Short       total data size for this block
    #         Flags         Byte        info bits
    #         (ModTime)     Long        time of last modification (UTC/GMT)
    #         (AcTime)      Long        time of last access (UTC/GMT)
    #         (CrTime)      Long        time of original creation (UTC/GMT)
    #
    #         Central-header version:
    #
    #         Value         Size        Description
    #         -----         ----        -----------
    # (time)  0x5455        Short       tag for this extra block type ("UT")
    #         TSize         Short       total data size for this block
    #         Flags         Byte        info bits (refers to local header!)
    #         (ModTime)     Long        time of last modification (UTC/GMT)
    #
    # The lower three bits of Flags in both headers indicate which time-
    #       stamps are present in the LOCAL extra field:
    #
    #       bit 0           if set, modification time is present
    #       bit 1           if set, access time is present
    #       bit 2           if set, creation time is present
    #       bits 3-7        reserved for additional timestamps; not set
    flags = 0b00000001 # Set the lowest bit only, to indicate that only mtime is present
    # The atime and ctime can be omitted if not present
    [
      # tag for this extra block type ("UT")
      0x5455,
      # the size of this block (1 byte used for the Flag + 3 longs used for the timestamp)
      (1 + 4),
      # encode a single byte
      flags,
      # Use a signed int, not the unsigned one used by the rest of the ZIP spec.
      # Time#utc would convert the given Time to UTC in-place, and the DOS time fields
      # computed from it afterwards would then be in UTC instead of local time
      mtime.to_i
    ].pack(TIMESTAMP_EXTRA_PACKSPEC)
  end

  # Since we do not supply atime or ctime, the contents of the two extra fields (central dir and local header)
  # is exactly the same, so we can use a method alias.
  alias_method :timestamp_extra_for_central_directory_entry, :timestamp_extra_for_local_file_header

  # Writes the Zip64 extra field for the central directory header.It differs from the extra used in the local file header because it
  # also contains the location of the local file header in the ZIP as an 8-byte int.
  #
  # @param compressed_size[Integer]    The size of the compressed (or stored) data - how much space it uses in the ZIP
  # @param uncompressed_size[Integer]  The size of the file once extracted
  # @param local_file_header_location[Integer] Byte offset of the start of the local file header from the beginning of the ZIP archive
  # @return [String]
  def zip_64_extra_for_central_directory_file_header(compressed_size:, uncompressed_size:, local_file_header_location:)
    [
      # 2 bytes    Tag for this "extra" block type
      0x0001,
      # 2 bytes    Size of this "extra" block. For us it will always be 28
      28,
      # 8 bytes    Original uncompressed file size
      uncompressed_size,
      # 8 bytes    Size of compressed data
      compressed_size,
      # 8 bytes    Offset of local header record
      local_file_header_location,
      # 4 bytes    Number of the disk on which this file starts
      0
    ].pack(ZIP64_EXTRA_FOR_CENTRAL_DIRECTORY_FILE_HEADER_PACKSPEC)
  end

  def to_binary_dos_time(t)
    (t.sec / 2) + (t.min << 5) + (t.hour << 11)
  end

  def to_binary_dos_date(t)
    t.day + (t.month << 5) + ((t.year - 1980) << 9)
  end

  def generate_external_attrs(unix_permissions_int, file_type_int)
    (file_type_int << 12 | (unix_permissions_int & 0o7777)) << 16
  end
end
