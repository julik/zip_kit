module ZipKit::Streamer::NoEncryption
  class Bypass
    def initialize(io)
      @io = io
    end

    def <<(b)
      @io << b
      self
    end

    def close
    end
  end

  def self.wrap_io(wrapping_closeable_io)
    Bypass.new(wrapping_closeable_io)
  end

  def self.extra_field_bytes
    "".b
  end

  def self.set_gp_bit1?
    false
  end

  def self.override_storage_mode
    nil
  end
end
