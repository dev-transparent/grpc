module HTTP2::HPACK
  # Encodes header lists into header blocks (RFC 7541). An encoder carries the
  # dynamic table state of one direction of a connection.
  class Encoder
    # Header names whose values are never added to the dynamic table and are
    # sent using the "never indexed" representation (section 7.1.3).
    SENSITIVE_HEADERS = Set{"authorization", "proxy-authorization", "cookie", "set-cookie"}

    # Fields larger than this are not indexed to avoid churning the table.
    MAX_INDEXED_ENTRY_SIZE = 1024

    getter table : DynamicTable
    property? huffman : Bool

    # Smallest and final table sizes set since the last header block.
    @pending_min_size : Int32? = nil
    @pending_size : Int32? = nil

    # *max_table_size* is the encoder's preferred maximum table size; the
    # effective size is bounded by the peer's SETTINGS_HEADER_TABLE_SIZE (see
    # `#peer_max_table_size=`).
    def initialize(@max_table_size : Int32 = 4096, @huffman : Bool = true)
      @table = DynamicTable.new(Math.min(@max_table_size, 4096))
    end

    # Updates the table size limit advertised by the peer. A dynamic table
    # size update is emitted at the start of the next header block.
    def peer_max_table_size=(limit : Int32) : Nil
      size = Math.min(limit, @max_table_size)
      return if size == @table.max_size && @pending_size.nil?
      @pending_min_size = Math.min(@pending_min_size || size, size)
      @pending_size = size
      @table.max_size = size
    end

    def encode(headers : Enumerable({String, String})) : Bytes
      io = IO::Memory.new
      encode(headers, io)
      io.to_slice
    end

    def encode(headers : Enumerable({String, String}), io : IO) : Nil
      if size = @pending_size
        # When the size shrank and grew again, the minimum must be signalled
        # first (section 4.2).
        min = @pending_min_size || size
        write_integer(io, min, 5, 0x20_u8) if min < size
        write_integer(io, size, 5, 0x20_u8)
        @pending_size = @pending_min_size = nil
      end

      headers.each do |name, value|
        encode_field(io, name, value)
      end
    end

    private def encode_field(io : IO, name : String, value : String) : Nil
      sensitive = SENSITIVE_HEADERS.includes?(name) && !(name == "cookie" && value.bytesize < 20)

      unless sensitive
        if index = STATIC_FIELD_INDEX[{name, value}]?
          write_integer(io, index, 7, 0x80_u8)
          return
        end
      end

      dyn_index, dyn_name_index = @table.find(name, value)
      if dyn_index && !sensitive
        write_integer(io, dyn_index + STATIC_TABLE_SIZE + 1, 7, 0x80_u8)
        return
      end

      name_index = STATIC_NAME_INDEX[name]? || dyn_name_index.try { |i| i + STATIC_TABLE_SIZE + 1 } || 0

      if sensitive
        write_integer(io, name_index, 4, 0x10_u8)
      elsif DynamicTable.entry_size(name, value) <= MAX_INDEXED_ENTRY_SIZE && @table.max_size > 0
        write_integer(io, name_index, 6, 0x40_u8)
        @table.add(name, value)
      else
        write_integer(io, name_index, 4, 0x00_u8)
      end
      write_string(io, name) if name_index == 0
      write_string(io, value)
    end

    # Integer representation (section 5.1).
    def write_integer(io : IO, value : Int32, prefix : Int32, flags : UInt8) : Nil
      max = (1 << prefix) - 1
      if value < max
        io.write_byte(flags | value.to_u8)
        return
      end
      io.write_byte(flags | max.to_u8)
      value -= max
      while value >= 128
        io.write_byte(((value & 0x7f) | 0x80).to_u8)
        value >>= 7
      end
      io.write_byte(value.to_u8)
    end

    # String literal representation (section 5.2).
    def write_string(io : IO, string : String) : Nil
      bytes = string.to_slice
      if huffman? && (encoded_size = Huffman.encoded_size(bytes)) < bytes.size
        write_integer(io, encoded_size, 7, 0x80_u8)
        Huffman.encode(bytes, io)
      else
        write_integer(io, bytes.size, 7, 0x00_u8)
        io.write(bytes)
      end
    end
  end
end
