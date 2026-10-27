module HTTP2::HPACK
  # Decodes header blocks (RFC 7541). A decoder carries the dynamic table state
  # of one direction of a connection, so every header block received on a
  # connection must be passed to the same decoder, in order.
  class Decoder
    # The maximum dynamic table size the peer may use, i.e. the value of our
    # SETTINGS_HEADER_TABLE_SIZE.
    property max_table_size_limit : Int32
    # Upper bound on the decoded header list size (RFC 9113 section 6.5.2
    # semantics: sum of name + value + 32 per field).
    property max_header_list_size : Int32

    getter table : DynamicTable

    def initialize(@max_table_size_limit : Int32 = 4096, @max_header_list_size : Int32 = Int32::MAX)
      @table = DynamicTable.new(@max_table_size_limit)
    end

    # Decodes a complete header block into an ordered list of fields.
    def decode(block : Bytes) : Array({String, String})
      headers = [] of {String, String}
      reader = Reader.new(block)
      list_size = 0_i64
      field_seen = false

      until reader.eof?
        byte = reader.peek
        if byte & 0x80 != 0
          # Indexed header field (section 6.1).
          index = reader.read_integer(7)
          raise DecompressionError.new("Indexed header field with index 0") if index == 0
          name, value = lookup(index)
          field_seen = true
        elsif byte & 0xc0 == 0x40
          # Literal header field with incremental indexing (section 6.2.1).
          name, value = read_literal(reader, 6)
          @table.add(name, value)
          field_seen = true
        elsif byte & 0xe0 == 0x20
          # Dynamic table size update (section 6.3).
          if field_seen
            raise DecompressionError.new("Dynamic table size update after header field")
          end
          size = reader.read_integer(5)
          if size > @max_table_size_limit
            raise DecompressionError.new("Dynamic table size update #{size} exceeds limit #{@max_table_size_limit}")
          end
          @table.max_size = size
          next
        else
          # Literal header field without indexing / never indexed
          # (sections 6.2.2 and 6.2.3); both use a 4 bit prefix.
          name, value = read_literal(reader, 4)
          field_seen = true
        end

        # Keep decoding when the list grows too large so that the dynamic
        # table stays synchronised with the peer's encoder.
        list_size += name.bytesize + value.bytesize + ENTRY_OVERHEAD
        headers << {name, value} unless list_size > @max_header_list_size
      end
      if list_size > @max_header_list_size
        raise HeaderListTooLargeError.new("Header list exceeds #{@max_header_list_size} octets")
      end
      headers
    end

    private def lookup(index : Int32) : {String, String}
      if index <= STATIC_TABLE_SIZE
        STATIC_TABLE[index - 1]
      else
        @table[index - STATIC_TABLE_SIZE - 1] || raise DecompressionError.new("Invalid header index #{index}")
      end
    end

    private def read_literal(reader : Reader, prefix : Int32) : {String, String}
      index = reader.read_integer(prefix)
      name = if index == 0
               reader.read_string
             else
               lookup(index)[0]
             end
      {name, reader.read_string}
    end

    # Cursor over a header block.
    class Reader
      @pos = 0

      def initialize(@data : Bytes)
      end

      def eof? : Bool
        @pos >= @data.size
      end

      def peek : UInt8
        @data[@pos]
      end

      def read_byte : UInt8
        raise DecompressionError.new("Truncated header block") if eof?
        byte = @data[@pos]
        @pos += 1
        byte
      end

      # Integer representation (section 5.1).
      def read_integer(prefix : Int32) : Int32
        mask = (1 << prefix) - 1
        value = (read_byte & mask).to_i64
        return value.to_i32 if value < mask
        shift = 0
        loop do
          byte = read_byte
          value += (byte & 0x7f).to_i64 << shift
          raise DecompressionError.new("Integer overflow in header block") if value > Int32::MAX
          shift += 7
          break if byte & 0x80 == 0
          raise DecompressionError.new("Integer overflow in header block") if shift > 28
        end
        value.to_i32
      end

      # String literal representation (section 5.2).
      def read_string : String
        raise DecompressionError.new("Truncated header block") if eof?
        huffman = peek & 0x80 != 0
        length = read_integer(7)
        if length > @data.size - @pos
          raise DecompressionError.new("String literal exceeds header block")
        end
        raw = @data[@pos, length]
        @pos += length
        String.new(huffman ? Huffman.decode(raw) : raw)
      end
    end
  end

  # Raised when the decoded header list exceeds the configured maximum size.
  class HeaderListTooLargeError < DecompressionError
  end
end
