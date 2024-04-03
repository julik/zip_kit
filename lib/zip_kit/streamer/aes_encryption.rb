require "securerandom"
require "openssl"

# https://www.winzip.com/en/support/aes-encryption/#auth-faq
# https://www.ruby-forum.com/t/make-aes-encrypted-zip-file-in-ruby/234782
# https://github.com/jphastings/rubyzip/blob/d226e0f5283a30a3a436f57277e8711846e9161f/lib/zip/extra_field/aes.rb#L3
# https://github.com/jphastings/rubyzip/blob/d226e0f5283a30a3a436f57277e8711846e9161f/lib/zip/decrypter.rb#L56
class ZipKit::Streamer::AESEncryption
  VERIFIER_LENGTH_BYTES = 2
  AUTHENTICATION_CODE_LENGTH_BYTES = 10
  BLOCK_SIZE_BYTES = 16

  class BlockEncryptor
    def initialize(io, cipher, mac)
      @io = io
      @cipher = cipher
      @mac = mac
      @block_n = 0
      @block_buffer = String.new.b
    end

    def <<(bytes)
      @block_buffer << bytes

      n_complete_blocks, remaining_bytes = @block_buffer.bytesize.divmod(BLOCK_SIZE_BYTES)
      n_complete_blocks.times do |n|
        block_bytes = @block_buffer.byteslice(n * BLOCK_SIZE_BYTES, BLOCK_SIZE_BYTES)
        write_block(block_bytes)
      end
      @block_buffer = @block_buffer.byteslice(n_complete_blocks * BLOCK_SIZE_BYTES, BLOCK_SIZE_BYTES)

      self
    end

    def close
      _, remaining_bytes = @block_buffer.bytesize.divmod(BLOCK_SIZE_BYTES)
      if remaining_bytes > 0
        write_block(@block_buffer)
      end

      final_block = @cipher.final
      @mac << final_block
      @io << final_block
      @io << @mac.digest.byteslice(0, AUTHENTICATION_CODE_LENGTH_BYTES)
    end

    def write_block(block_bytes)
      @block_n += 1
      @cipher.iv = [@block_n].pack("Vx12") # Reverse engineered this value from Zip4j's AES support.
      encrypted_block_bytes = @cipher.update(block_bytes)
      @io << encrypted_block_bytes
      @mac << encrypted_block_bytes
    end
  end

  def initialize(password:, storage_mode:, encryption_strength: 3)
    @encryption_strength = encryption_strength

    n = encryption_strength + 1
    @bits = 64 * n
    @key_length = 8 * n
    @mac_key_length = 8 * n
    @salt_length = 4 * n

    @salt = SecureRandom.bytes(@salt_length)
    @storage_mode = storage_mode

    # Derive the password with BKDF and 1000 revolutions
    # @encryption_key = OpenSSL::PKCS5.pbkdf2_hmac_sha1(
    #         password,
    #         @salt,
    #         1000,
    #         @key_length + @mac_length + VERIFIER_LENGTH_BYTES
    # )
    # Modern syntax: https://ruby-doc.org/3.2.2/exts/openssl/OpenSSL/KDF.html#method-c-pbkdf2_hmac
    key_mac_and_verification_bytes = OpenSSL::PKCS5.pbkdf2_hmac_sha1(
            password,
            @salt,
            1000,
            @key_length + @mac_key_length + VERIFIER_LENGTH_BYTES
    )
    @encryption_key = key_mac_and_verification_bytes.byteslice(0, @key_length)
    @mac_key = key_mac_and_verification_bytes.byteslice(@key_length, @mac_key_length)
    @verification_code = key_mac_and_verification_bytes.byteslice(key_mac_and_verification_bytes.bytesize - 2, 2)
  end

  def wrap_io(io)
    io << @salt
    io << @verification_code

    cipher = OpenSSL::Cipher::AES.new(@bits, :CTR)
    cipher.encrypt
    cipher.key = @encryption_key

    hmac = OpenSSL::HMAC.new(@mac_key, OpenSSL::Digest::SHA1.new)
    BlockEncryptor.new(io, cipher, hmac)
  end

  def extra_field_bytes
    # Offset  Size(bytes)   Content
    # 0       2             Extra field header ID (0x9901)
    # 2       2             Data size (currently 7, but subject to possible increase in the future)
    # 4       2             Integer version number specific to the zip vendor
    # 6       2             2-character vendor ID
    # 8       1             Integer mode value indicating AES encryption strength (0x01, 0x02, 0x03)
    # 9       2             The actual compression method used to compress the file
    "".b.tap do |buf|
      buf << [0x9901].pack("v")
      buf << [7].pack("v")
      buf << [0x0002].pack("v")
      buf << "AE"
      buf << [@encryption_strength].pack("C")
      buf << [@storage_mode].pack("v")
    end
  end

  def set_gp_bit1?
    true
  end

  def override_storage_mode
    99
  end
end


enc = ZipKit::Streamer::AESEncryption.new(password: "xxx", storage_mode: 8)
io = StringIO.new
w = enc.wrap_io(io)
w << Random.bytes(25682898); nil
