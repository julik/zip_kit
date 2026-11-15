require "test_helper"

# The rules come from https://www.w3.org/TR/epub-33/#sec-zip-container-mime
# and OpenDocument v1.3 part 2, section 3.3 - which both boil down to the same byte layout
class OcfTest < TestCase
  def media_type
    @media_type ||= "application/epub+zip"
  end

  def local_header_at(bytes, offset)
    _sig, _version, gp_flags, storage_mode, _time, _date, crc32, compressed_size, uncompressed_size,
      filename_size, extra_size = bytes.byteslice(offset, 30).unpack("VvvvvvVVVvv")
    filename = bytes.byteslice(offset + 30, filename_size)
    {gp_flags: gp_flags, storage_mode: storage_mode, crc32: crc32, compressed_size: compressed_size,
     uncompressed_size: uncompressed_size, filename: filename, extra_size: extra_size,
     body_offset: offset + 30 + filename_size + extra_size}
  end

  def write_book(out)
    ZipKit::Streamer.open(out, ocf: true) do |zip|
      zip.write_mimetype_file(media_type)
      zip.write_file("META-INF/container.xml") { |sink| sink << "<container/>" * 64 }
      zip.write_stored_file("OEBPS/cover.jpg") { |sink| sink << Random.bytes(1024) }
      zip.write_deflated_file("OEBPS/chapter.xhtml") { |sink| sink << "<p>Hello</p>" * 64 }
    end
  end

  test "produces an archive which starts with a conformant mimetype entry" do
    out = StringIO.new(+"")
    write_book(out)
    bytes = out.string

    assert_equal "PK\x03\x04".b, bytes.byteslice(0, 4)
    header = local_header_at(bytes, 0)
    assert_equal "mimetype", header[:filename]
    assert_equal 0, header[:storage_mode] # stored
    assert_equal 0, header[:extra_size]
    assert_equal 0, header[:gp_flags] & 0x0008 # no data descriptor, sizes are in the header
    assert_equal 20, header[:compressed_size]
    assert_equal 20, header[:uncompressed_size]
    assert_equal Zlib.crc32(media_type), header[:crc32]

    # This is what readers sniff for, the "magic" of an EPUB
    assert_equal "mimetype", bytes.byteslice(30, 8)
    assert_equal media_type, bytes.byteslice(38, 20)
    assert_equal "PK\x03\x04".b, bytes.byteslice(58, 4) # the next entry follows right away
  end

  test "keeps the extended timestamps on the entries which are not the mimetype" do
    out = StringIO.new(+"")
    write_book(out)

    entries = ZipKit::FileReader.read_zip_structure(io: out)
    assert_equal ["mimetype", "META-INF/container.xml", "OEBPS/cover.jpg", "OEBPS/chapter.xhtml"], entries.map(&:filename)
    entries.drop(1).each do |entry|
      assert_equal 9, local_header_at(out.string, entry.local_file_header_offset)[:extra_size]
    end
  end

  test "produces an archive other readers can extract" do
    tf = Tempfile.new("book.epub")
    tf.binmode
    write_book(tf)
    tf.flush

    contents = {}
    Zip::File.open(tf.path) do |zip_file|
      zip_file.each { |entry| contents[entry.name] = entry.get_input_stream.read }
    end
    assert_equal "mimetype", contents.keys.first
    assert_equal media_type, contents["mimetype"]
    assert_equal "<p>Hello</p>" * 64, contents["OEBPS/chapter.xhtml"]
  ensure
    tf&.close!
  end

  test "makes the SizeEstimator agree with the actual size" do
    estimate = ZipKit::SizeEstimator.estimate(ocf: true) do |zip|
      zip.add_mimetype_entry(media_type: media_type)
      zip.add_stored_entry(filename: "OEBPS/cover.jpg", size: 1024)
    end

    out = StringIO.new(+"")
    ZipKit::Streamer.open(out, ocf: true) do |zip|
      zip.write_mimetype_file(media_type)
      zip.add_stored_entry(filename: "OEBPS/cover.jpg", size: 1024)
      zip << Random.bytes(1024)
    end
    assert_equal out.size, estimate
  end

  test "accepts a mimetype entry with known size written via add_stored_entry" do
    out = StringIO.new(+"")
    ZipKit::Streamer.open(out, ocf: true) do |zip|
      zip.add_stored_entry(filename: "mimetype", size: media_type.bytesize, crc32: Zlib.crc32(media_type))
      zip << media_type
    end
    assert_equal 0, local_header_at(out.string, 0)[:extra_size]
    assert_equal media_type, out.string.byteslice(38, 20)
  end

  describe "refusing to write a non-conformant archive" do
    def out
      @out ||= StringIO.new(+"")
    end

    def zip
      @zip ||= ZipKit::Streamer.new(out, ocf: true)
    end

    test "refuses a first entry which is not the mimetype, without writing anything" do
      error = assert_raises(ZipKit::Streamer::OCFViolation) {
        zip.write_file("META-INF/container.xml") { |sink| sink << "<container/>" }
      }
      assert_match(/it is "META-INF\/container.xml"/, error.message)
      assert_equal 0, out.size
    end

    test "refuses a compressed mimetype" do
      error = assert_raises(ZipKit::Streamer::OCFViolation) {
        zip.add_deflated_entry(filename: "mimetype", compressed_size: 22, uncompressed_size: 20)
      }
      assert_match(/compressed/, error.message)
    end

    test "refuses a mimetype with a data descriptor" do
      error = assert_raises(ZipKit::Streamer::OCFViolation) {
        zip.write_stored_file("mimetype") { |sink| sink << media_type }
      }
      assert_match(/data descriptor/, error.message)
    end

    test "refuses a media type with whitespace or padding" do
      assert_raises(ZipKit::Streamer::OCFViolation) { zip.write_mimetype_file("#{media_type}\n") }
      assert_raises(ZipKit::Streamer::OCFViolation) { zip.write_mimetype_file(" #{media_type}") }
      assert_raises(ZipKit::Streamer::OCFViolation) { zip.write_mimetype_file("") }
      assert_raises(ZipKit::Streamer::OCFViolation) { zip.write_mimetype_file("application/épub+zip") }
      assert_equal 0, out.size
    end

    test "refuses further entries once the mimetype has been rolled back" do
      zip.add_stored_entry(filename: "mimetype", size: 20, crc32: Zlib.crc32(media_type))
      zip << "applica" # and then the source fails
      zip.rollback!

      error = assert_raises(ZipKit::Streamer::OCFViolation) { zip.write_mimetype_file(media_type) }
      assert_match(/offset 0/, error.message)
    end
  end

  describe "file names" do
    def out
      @out ||= StringIO.new(+"")
    end

    def zip
      @zip ||= ZipKit::Streamer.new(out, ocf: true).tap { |z| z.write_mimetype_file(media_type) }
    end

    def add(filename)
      zip.add_stored_entry(filename: filename, size: 0)
    end

    test "accepts the names a typical book has, including non-ASCII ones" do
      ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/Text/chapter-01.xhtml", "OEBPS/Images/",
        "OEBPS/Text/第一章.xhtml", "OEBPS/Text/café.xhtml", "OEBPS/.hidden", "OEBPS/Text/with space.xhtml"].each do |name|
        assert_nothing_raised { add(name) }
      end
    end

    test "refuses forbidden characters" do
      ["a\"b", "a*b", "a:b", "a<b", "a>b", "a?b", "a|b", "a\u0000b", "a\u001Fb", "a\u007Fb", "a\u0085b",
        "a\uE000b", "a\uF8FFb", "a\uFDD0b", "a\uFFFEb", "a\uFFF9b", "a\u{1FFFE}b", "a\u{EFFFF}b", "a\u{F0000}b",
        "a\u{10FFFD}b", "OEBPS/a:b/c.xhtml"].each do |name|
        error = assert_raises(ZipKit::Streamer::OCFViolation, "expected #{name.inspect} to be refused") { add(name) }
        assert_match(/forbidden character/, error.message, "expected #{name.inspect} to be refused")
      end
    end

    test "refuses segments ending with a full stop, which also covers relative paths" do
      ["chapter.", "OEBPS./a.xhtml", "../evil.xhtml", "OEBPS/./a.xhtml"].each do |name|
        error = assert_raises(ZipKit::Streamer::OCFViolation, "expected #{name.inspect} to be refused") { add(name) }
        assert_match(/ending with a "."/, error.message, "expected #{name.inspect} to be refused")
      end
    end

    test "refuses absolute paths and empty segments" do
      ["/OEBPS/a.xhtml", "OEBPS//a.xhtml"].each do |name|
        error = assert_raises(ZipKit::Streamer::OCFViolation) { add(name) }
        assert_match(/empty path segment/, error.message)
      end
    end

    test "refuses segments longer than 255 bytes, but not long paths made of shorter segments" do
      error = assert_raises(ZipKit::Streamer::OCFViolation) { add("OEBPS/" + "a" * 256) }
      assert_match(/255 bytes/, error.message)
      error = assert_raises(ZipKit::Streamer::OCFViolation) { add("OEBPS/" + "é" * 128) } # 256 bytes
      assert_match(/255 bytes/, error.message)
      assert_nothing_raised { add("OEBPS/" + "a" * 255) }
      assert_nothing_raised { add((["b" * 200] * 4).join("/")) }
    end

    test "refuses names which are not valid UTF-8" do
      error = assert_raises(ZipKit::Streamer::OCFViolation) { add("OEBPS/\xFF.xhtml".b) }
      assert_match(/UTF-8/, error.message)
    end

    test "refuses names which only differ by case from an existing one" do
      add("OEBPS/Chapter.xhtml")
      error = assert_raises(ZipKit::Streamer::OCFViolation) { add("OEBPS/chapter.xhtml") }
      assert_match(/by case/, error.message)
      error = assert_raises(ZipKit::Streamer::OCFViolation) { add("OEBPS/CHAPTER.XHTML") }
      assert_match(/by case/, error.message)
      assert_nothing_raised { add("Other/chapter.xhtml") } # same name, different directory
    end

    test "applies full case folding" do
      add("OEBPS/straße.xhtml")
      assert_raises(ZipKit::Streamer::OCFViolation) { add("OEBPS/STRASSE.xhtml") }
    end

    test "refuses names which only differ by Unicode normalization from an existing one" do
      add("OEBPS/caf\u00E9.xhtml") # precomposed
      error = assert_raises(ZipKit::Streamer::OCFViolation) { add("OEBPS/cafe\u0301.xhtml") } # decomposed
      assert_match(/normalization/, error.message)
    end

    test "refuses directories which only differ by case" do
      add("OEBPS/a.xhtml")
      error = assert_raises(ZipKit::Streamer::OCFViolation) { add("oebps/b.xhtml") }
      assert_match(/"oebps" only differs from "OEBPS"/, error.message)
      assert_raises(ZipKit::Streamer::OCFViolation) { add("oebps/") }
      assert_nothing_raised { add("OEBPS/b.xhtml") }
    end

    test "forgets the names of rolled back entries" do
      add("OEBPS/Chapter.xhtml")
      zip.rollback!
      assert_nothing_raised { add("OEBPS/chapter.xhtml") }
    end

    test "does not check file names without ocf: true" do
      assert_nothing_raised do
        ZipKit::Streamer.open(StringIO.new(+"")) do |plain|
          plain.add_stored_entry(filename: "a:b?", size: 0)
          plain.add_stored_entry(filename: "A:B?", size: 0)
        end
      end
    end
  end

  describe "without ocf: true" do
    test "does not care what the first entry is" do
      out = StringIO.new(+"")
      ZipKit::Streamer.open(out) do |zip|
        zip.write_file("readme.txt") { |sink| sink << "Hi" }
        zip.write_mimetype_file(media_type)
      end
      assert_equal ["readme.txt", "mimetype"], ZipKit::FileReader.read_zip_structure(io: out).map(&:filename)
    end

    test "still writes the mimetype file without extra fields" do
      out = StringIO.new(+"")
      ZipKit::Streamer.open(out) { |zip| zip.write_mimetype_file(media_type) }
      assert_equal 0, out.string.byteslice(28, 2).unpack1("v") # extra field length
    end
  end
end
