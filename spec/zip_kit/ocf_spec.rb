require_relative "../spec_helper"

# The rules come from https://www.w3.org/TR/epub-33/#sec-zip-container-mime
# and OpenDocument v1.3 part 2, section 3.3 - which both boil down to the same byte layout
describe "ZipKit::Streamer with ocf: true" do
  let(:media_type) { "application/epub+zip" }

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

  it "produces an archive which starts with a conformant mimetype entry" do
    out = StringIO.new(+"")
    write_book(out)
    bytes = out.string

    expect(bytes.byteslice(0, 4)).to eq("PK\x03\x04".b)
    header = local_header_at(bytes, 0)
    expect(header[:filename]).to eq("mimetype")
    expect(header[:storage_mode]).to eq(0) # stored
    expect(header[:extra_size]).to eq(0)
    expect(header[:gp_flags] & 0x0008).to eq(0) # no data descriptor, sizes are in the header
    expect(header[:compressed_size]).to eq(20)
    expect(header[:uncompressed_size]).to eq(20)
    expect(header[:crc32]).to eq(Zlib.crc32(media_type))

    # This is what readers sniff for, the "magic" of an EPUB
    expect(bytes.byteslice(30, 8)).to eq("mimetype")
    expect(bytes.byteslice(38, 20)).to eq(media_type)
    expect(bytes.byteslice(58, 4)).to eq("PK\x03\x04".b) # the next entry follows right away
  end

  it "keeps the extended timestamps on the entries which are not the mimetype" do
    out = StringIO.new(+"")
    write_book(out)

    entries = ZipKit::FileReader.read_zip_structure(io: out)
    expect(entries.map(&:filename)).to eq(["mimetype", "META-INF/container.xml", "OEBPS/cover.jpg", "OEBPS/chapter.xhtml"])
    entries.drop(1).each do |entry|
      expect(local_header_at(out.string, entry.local_file_header_offset)[:extra_size]).to eq(9)
    end
  end

  it "produces an archive other readers can extract" do
    tf = Tempfile.new("book.epub")
    tf.binmode
    write_book(tf)
    tf.flush

    contents = {}
    Zip::File.open(tf.path) do |zip_file|
      zip_file.each { |entry| contents[entry.name] = entry.get_input_stream.read }
    end
    expect(contents.keys.first).to eq("mimetype")
    expect(contents["mimetype"]).to eq(media_type)
    expect(contents["OEBPS/chapter.xhtml"]).to eq("<p>Hello</p>" * 64)
  ensure
    tf&.close!
  end

  it "makes the SizeEstimator agree with the actual size" do
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
    expect(estimate).to eq(out.size)
  end

  it "accepts a mimetype entry with known size written via add_stored_entry" do
    out = StringIO.new(+"")
    ZipKit::Streamer.open(out, ocf: true) do |zip|
      zip.add_stored_entry(filename: "mimetype", size: media_type.bytesize, crc32: Zlib.crc32(media_type))
      zip << media_type
    end
    expect(local_header_at(out.string, 0)[:extra_size]).to eq(0)
    expect(out.string.byteslice(38, 20)).to eq(media_type)
  end

  describe "refusing to write a non-conformant archive" do
    let(:out) { StringIO.new(+"") }
    let(:zip) { ZipKit::Streamer.new(out, ocf: true) }

    it "refuses a first entry which is not the mimetype, without writing anything" do
      expect {
        zip.write_file("META-INF/container.xml") { |sink| sink << "<container/>" }
      }.to raise_error(ZipKit::Streamer::OCFViolation, /it is "META-INF\/container.xml"/)
      expect(out.size).to eq(0)
    end

    it "refuses a compressed mimetype" do
      expect {
        zip.add_deflated_entry(filename: "mimetype", compressed_size: 22, uncompressed_size: 20)
      }.to raise_error(ZipKit::Streamer::OCFViolation, /compressed/)
    end

    it "refuses a mimetype with a data descriptor" do
      expect {
        zip.write_stored_file("mimetype") { |sink| sink << media_type }
      }.to raise_error(ZipKit::Streamer::OCFViolation, /data descriptor/)
    end

    it "refuses a media type with whitespace or padding" do
      expect { zip.write_mimetype_file("#{media_type}\n") }.to raise_error(ZipKit::Streamer::OCFViolation)
      expect { zip.write_mimetype_file(" #{media_type}") }.to raise_error(ZipKit::Streamer::OCFViolation)
      expect { zip.write_mimetype_file("") }.to raise_error(ZipKit::Streamer::OCFViolation)
      expect { zip.write_mimetype_file("application/épub+zip") }.to raise_error(ZipKit::Streamer::OCFViolation)
      expect(out.size).to eq(0)
    end

    it "refuses further entries once the mimetype has been rolled back" do
      zip.add_stored_entry(filename: "mimetype", size: 20, crc32: Zlib.crc32(media_type))
      zip << "applica" # and then the source fails
      zip.rollback!

      expect { zip.write_mimetype_file(media_type) }.to raise_error(ZipKit::Streamer::OCFViolation, /offset 0/)
    end
  end

  describe "file names" do
    let(:out) { StringIO.new(+"") }
    let(:zip) { ZipKit::Streamer.new(out, ocf: true).tap { |z| z.write_mimetype_file(media_type) } }

    def add(filename)
      zip.add_stored_entry(filename: filename, size: 0)
    end

    it "accepts the names a typical book has, including non-ASCII ones" do
      ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/Text/chapter-01.xhtml", "OEBPS/Images/",
        "OEBPS/Text/第一章.xhtml", "OEBPS/Text/café.xhtml", "OEBPS/.hidden", "OEBPS/Text/with space.xhtml"].each do |name|
        expect { add(name) }.not_to raise_error
      end
    end

    it "refuses forbidden characters" do
      ["a\"b", "a*b", "a:b", "a<b", "a>b", "a?b", "a|b", "a\u0000b", "a\u001Fb", "a\u007Fb", "a\u0085b",
        "a\uE000b", "a\uF8FFb", "a\uFDD0b", "a\uFFFEb", "a\uFFF9b", "a\u{1FFFE}b", "a\u{EFFFF}b", "a\u{F0000}b",
        "a\u{10FFFD}b", "OEBPS/a:b/c.xhtml"].each do |name|
        expect { add(name) }.to raise_error(ZipKit::Streamer::OCFViolation, /forbidden character/), "expected #{name.inspect} to be refused"
      end
    end

    it "refuses segments ending with a full stop, which also covers relative paths" do
      ["chapter.", "OEBPS./a.xhtml", "../evil.xhtml", "OEBPS/./a.xhtml"].each do |name|
        expect { add(name) }.to raise_error(ZipKit::Streamer::OCFViolation, /ending with a "."/), "expected #{name.inspect} to be refused"
      end
    end

    it "refuses absolute paths and empty segments" do
      ["/OEBPS/a.xhtml", "OEBPS//a.xhtml"].each do |name|
        expect { add(name) }.to raise_error(ZipKit::Streamer::OCFViolation, /empty path segment/)
      end
    end

    it "refuses segments longer than 255 bytes, but not long paths made of shorter segments" do
      expect { add("OEBPS/" + "a" * 256) }.to raise_error(ZipKit::Streamer::OCFViolation, /255 bytes/)
      expect { add("OEBPS/" + "é" * 128) }.to raise_error(ZipKit::Streamer::OCFViolation, /255 bytes/) # 256 bytes
      expect { add("OEBPS/" + "a" * 255) }.not_to raise_error
      expect { add((["b" * 200] * 4).join("/")) }.not_to raise_error
    end

    it "refuses names which are not valid UTF-8" do
      expect { add("OEBPS/\xFF.xhtml".b) }.to raise_error(ZipKit::Streamer::OCFViolation, /UTF-8/)
    end

    it "refuses names which only differ by case from an existing one" do
      add("OEBPS/Chapter.xhtml")
      expect { add("OEBPS/chapter.xhtml") }.to raise_error(ZipKit::Streamer::OCFViolation, /by case/)
      expect { add("OEBPS/CHAPTER.XHTML") }.to raise_error(ZipKit::Streamer::OCFViolation, /by case/)
      expect { add("Other/chapter.xhtml") }.not_to raise_error # same name, different directory
    end

    it "applies full case folding" do
      add("OEBPS/straße.xhtml")
      expect { add("OEBPS/STRASSE.xhtml") }.to raise_error(ZipKit::Streamer::OCFViolation)
    end

    it "refuses names which only differ by Unicode normalization from an existing one" do
      add("OEBPS/caf\u00E9.xhtml") # precomposed
      expect { add("OEBPS/cafe\u0301.xhtml") }.to raise_error(ZipKit::Streamer::OCFViolation, /normalization/) # decomposed
    end

    it "refuses directories which only differ by case" do
      add("OEBPS/a.xhtml")
      expect { add("oebps/b.xhtml") }.to raise_error(ZipKit::Streamer::OCFViolation, /"oebps" only differs from "OEBPS"/)
      expect { add("oebps/") }.to raise_error(ZipKit::Streamer::OCFViolation)
      expect { add("OEBPS/b.xhtml") }.not_to raise_error
    end

    it "forgets the names of rolled back entries" do
      add("OEBPS/Chapter.xhtml")
      zip.rollback!
      expect { add("OEBPS/chapter.xhtml") }.not_to raise_error
    end

    it "does not check file names without ocf: true" do
      ZipKit::Streamer.open(StringIO.new(+"")) do |plain|
        plain.add_stored_entry(filename: "a:b?", size: 0)
        plain.add_stored_entry(filename: "A:B?", size: 0)
      end
    end
  end

  describe "without ocf: true" do
    it "does not care what the first entry is" do
      out = StringIO.new(+"")
      ZipKit::Streamer.open(out) do |zip|
        zip.write_file("readme.txt") { |sink| sink << "Hi" }
        zip.write_mimetype_file(media_type)
      end
      expect(ZipKit::FileReader.read_zip_structure(io: out).map(&:filename)).to eq(["readme.txt", "mimetype"])
    end

    it "still writes the mimetype file without extra fields" do
      out = StringIO.new(+"")
      ZipKit::Streamer.open(out) { |zip| zip.write_mimetype_file(media_type) }
      expect(out.string.byteslice(28, 2).unpack1("v")).to eq(0) # extra field length
    end
  end
end
