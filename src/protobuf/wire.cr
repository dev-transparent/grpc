module Protobuf
  # Base class of the errors raised by the protobuf runtime.
  class Error < Exception
  end

  # Raised when protobuf binary data is malformed.
  class DecodeError < Error
  end

  # Raised when required fields of a proto2 message are not set (see
  # `Message#check_required_fields!`).
  class RequiredFieldsError < Error
    getter fields : Array(String)

    def initialize(@fields : Array(String), message_name : String)
      super("Message #{message_name} is missing required fields: #{@fields.join(", ")}")
    end
  end

  # Wire types (https://protobuf.dev/programming-guides/encoding/).
  enum WireType : UInt8
    Varint          = 0
    Fixed64         = 1
    LengthDelimited = 2
    StartGroup      = 3
    EndGroup        = 4
    Fixed32         = 5
  end

  MAX_FIELD_NUMBER        = 536_870_911
  DEFAULT_RECURSION_LIMIT =         100

  # Returns `true` if *value* is the proto3 default for its type. Used to
  # decide whether fields without explicit presence are serialized.
  def self.default?(value : String) : Bool
    value.empty?
  end

  def self.default?(value : Bytes) : Bool
    value.empty?
  end

  def self.default?(value : Bool) : Bool
    !value
  end

  def self.default?(value : Int::Primitive) : Bool
    value == 0
  end

  # Negative zero is not the default value; compare the bit pattern.
  def self.default?(value : Float32) : Bool
    value.unsafe_as(UInt32) == 0
  end

  def self.default?(value : Float64) : Bool
    value.unsafe_as(UInt64) == 0
  end

  def self.default?(value : Enum) : Bool
    value.value == 0
  end

  # Encodes protobuf wire format to an `IO`. Each `write_<type>_field`
  # method writes a complete field (tag and value).
  struct Writer
    getter io : IO

    def initialize(@io : IO)
    end

    def write_tag(number : Int32, wire_type : WireType) : Nil
      write_varint((number.to_u64 << 3) | wire_type.value)
    end

    def write_varint(value : UInt64) : Nil
      while value >= 0x80
        @io.write_byte((value & 0x7f).to_u8! | 0x80)
        value >>= 7
      end
      @io.write_byte(value.to_u8!)
    end

    def write_fixed32(value : UInt32) : Nil
      @io.write_bytes(value, IO::ByteFormat::LittleEndian)
    end

    def write_fixed64(value : UInt64) : Nil
      @io.write_bytes(value, IO::ByteFormat::LittleEndian)
    end

    def write_length_prefixed(bytes : Bytes) : Nil
      write_varint(bytes.size.to_u64)
      @io.write(bytes)
    end

    # --- Scalar values (no tag) ---

    def write_int32(value : Int32) : Nil
      # Negative values are sign extended to 64 bits (10 bytes).
      write_varint(value.to_i64.to_u64!)
    end

    def write_int64(value : Int64) : Nil
      write_varint(value.to_u64!)
    end

    def write_uint32(value : UInt32) : Nil
      write_varint(value.to_u64)
    end

    def write_uint64(value : UInt64) : Nil
      write_varint(value)
    end

    def write_sint32(value : Int32) : Nil
      write_varint(((value << 1) ^ (value >> 31)).to_u32!.to_u64)
    end

    def write_sint64(value : Int64) : Nil
      write_varint(((value << 1) ^ (value >> 63)).to_u64!)
    end

    def write_bool(value : Bool) : Nil
      @io.write_byte(value ? 1_u8 : 0_u8)
    end

    def write_enum(value : Enum) : Nil
      write_int32(value.value.to_i32!)
    end

    def write_fixed32(value : Int32) : Nil
      write_fixed32(value.to_u32!)
    end

    def write_sfixed32(value : Int32) : Nil
      write_fixed32(value.to_u32!)
    end

    def write_fixed64(value : Int64) : Nil
      write_fixed64(value.to_u64!)
    end

    def write_sfixed64(value : Int64) : Nil
      write_fixed64(value.to_u64!)
    end

    def write_float(value : Float32) : Nil
      write_fixed32(value.unsafe_as(UInt32))
    end

    def write_double(value : Float64) : Nil
      write_fixed64(value.unsafe_as(UInt64))
    end

    def write_string(value : String) : Nil
      write_length_prefixed(value.to_slice)
    end

    def write_bytes(value : Bytes) : Nil
      write_length_prefixed(value)
    end

    def write_message(value : Message) : Nil
      write_length_prefixed(value.to_protobuf)
    end

    # Writes *value* using group (delimited) encoding: the message fields
    # followed by an end group tag for *number*. The start group tag is
    # written by `#write_group_field`.
    def write_group(value : Message, number : Int32) : Nil
      value.to_protobuf(@io)
      write_tag(number, WireType::EndGroup)
    end

    def write_group_field(number : Int32, value : Message) : Nil
      write_tag(number, WireType::StartGroup)
      write_group(value, number)
    end

    # --- Complete fields (tag + value) ---

    {% for kind, wire in {
                           int32: :Varint, int64: :Varint, uint32: :Varint, uint64: :Varint,
                           sint32: :Varint, sint64: :Varint, bool: :Varint, enum: :Varint,
                           fixed32: :Fixed32, sfixed32: :Fixed32, float: :Fixed32,
                           fixed64: :Fixed64, sfixed64: :Fixed64, double: :Fixed64,
                           string: :LengthDelimited, bytes: :LengthDelimited, message: :LengthDelimited,
                         } %}
      def write_{{kind.id}}_field(number : Int32, value) : Nil
        write_tag(number, WireType::{{wire.id}})
        write_{{kind.id}}(value)
      end
    {% end %}

    # Writes a packed repeated field.
    {% for kind in %i(int32 int64 uint32 uint64 sint32 sint64 bool enum fixed32 sfixed32 float fixed64 sfixed64 double) %}
      def write_packed_{{kind.id}}(number : Int32, values : Array) : Nil
        return if values.empty?
        write_length_delimited(number) do |writer|
          values.each { |value| writer.write_{{kind.id}}(value) }
        end
      end
    {% end %}

    # Writes a length-delimited field whose content is produced by the block.
    def write_length_delimited(number : Int32, & : Writer ->) : Nil
      buffer = IO::Memory.new
      yield Writer.new(buffer)
      write_tag(number, WireType::LengthDelimited)
      write_length_prefixed(buffer.to_slice)
    end
  end

  # Decodes protobuf wire format from a byte slice.
  class Reader
    getter bytes : Bytes
    getter pos : Int32 = 0
    getter depth : Int32

    def initialize(@bytes : Bytes, @depth : Int32 = 0)
    end

    def eof? : Bool
      @pos >= @bytes.size
    end

    def remaining : Int32
      @bytes.size - @pos
    end

    # Reads a field tag, returning the field number and wire type.
    def read_tag : {Int32, WireType}
      raw = read_tag_varint
      number = raw >> 3
      raise DecodeError.new("Invalid field number 0") if number == 0
      raise DecodeError.new("Field number #{number} out of range") if number > MAX_FIELD_NUMBER
      wire_type = WireType.from_value?((raw & 7).to_u8) || raise DecodeError.new("Invalid wire type #{raw & 7}")
      {number.to_i32, wire_type}
    end

    # Tags are 32-bit varints of at most 5 bytes.
    private def read_tag_varint : UInt64
      result = 0_u64
      5.times do |i|
        raise DecodeError.new("Truncated tag") if eof?
        byte = @bytes[@pos]
        @pos += 1
        result |= (byte & 0x7f).to_u64 << (7 * i)
        if byte < 0x80
          raise DecodeError.new("Tag overflows 32 bits") if result > UInt32::MAX
          return result
        end
      end
      raise DecodeError.new("Tag varint too long")
    end

    def read_varint : UInt64
      result = 0_u64
      shift = 0
      loop do
        raise DecodeError.new("Truncated varint") if eof?
        byte = @bytes[@pos]
        @pos += 1
        # Like the reference implementations, bits of the tenth byte beyond
        # 64 bits are dropped.
        result |= (byte & 0x7f).to_u64 << shift
        return result if byte < 0x80
        shift += 7
        raise DecodeError.new("Varint too long") if shift > 63
      end
    end

    def read_fixed32_raw : UInt32
      raise DecodeError.new("Truncated fixed32") if remaining < 4
      value = IO::ByteFormat::LittleEndian.decode(UInt32, @bytes[@pos, 4])
      @pos += 4
      value
    end

    def read_fixed64_raw : UInt64
      raise DecodeError.new("Truncated fixed64") if remaining < 8
      value = IO::ByteFormat::LittleEndian.decode(UInt64, @bytes[@pos, 8])
      @pos += 8
      value
    end

    # Reads a length-delimited payload and returns it as a slice of the
    # underlying buffer (no copy).
    def read_length_delimited : Bytes
      length = read_varint
      raise DecodeError.new("Length-delimited field exceeds buffer") if length > remaining
      slice = @bytes[@pos, length.to_i32]
      @pos += length.to_i32
      slice
    end

    # Returns a reader over the next length-delimited payload, one nesting
    # level deeper.
    def read_sub_reader : Reader
      raise DecodeError.new("Recursion limit exceeded") if @depth >= DEFAULT_RECURSION_LIMIT
      Reader.new(read_length_delimited, @depth + 1)
    end

    def read_int32 : Int32
      read_varint.to_i32!
    end

    def read_int64 : Int64
      read_varint.to_i64!
    end

    def read_uint32 : UInt32
      read_varint.to_u32!
    end

    def read_uint64 : UInt64
      read_varint
    end

    def read_sint32 : Int32
      n = read_varint.to_u32!
      ((n >> 1) ^ (0_u32 &- (n & 1))).to_i32!
    end

    def read_sint64 : Int64
      n = read_varint
      ((n >> 1) ^ (0_u64 &- (n & 1))).to_i64!
    end

    def read_bool : Bool
      read_varint != 0
    end

    def read_enum : Int32
      read_varint.to_i32!
    end

    def read_fixed32 : UInt32
      read_fixed32_raw
    end

    def read_sfixed32 : Int32
      read_fixed32_raw.to_i32!
    end

    def read_float : Float32
      read_fixed32_raw.unsafe_as(Float32)
    end

    def read_fixed64 : UInt64
      read_fixed64_raw
    end

    def read_sfixed64 : Int64
      read_fixed64_raw.to_i64!
    end

    def read_double : Float64
      read_fixed64_raw.unsafe_as(Float64)
    end

    # Reads a string, validating UTF-8 unless *validate* is false.
    def read_string(validate : Bool = true) : String
      string = String.new(read_length_delimited)
      if validate && !string.valid_encoding?
        raise DecodeError.new("String field contains invalid UTF-8")
      end
      string
    end

    def read_bytes : Bytes
      read_length_delimited.dup
    end

    # Increments the nesting depth for a group read from this reader,
    # raising if the recursion limit is exceeded. Must be balanced by
    # `#leave_group`.
    def enter_group : Nil
      raise DecodeError.new("Recursion limit exceeded") if @depth >= DEFAULT_RECURSION_LIMIT
      @depth += 1
    end

    def leave_group : Nil
      @depth -= 1
    end

    # Yields for each value of a packed repeated field.
    def read_packed(& : Reader ->) : Nil
      sub = Reader.new(read_length_delimited, @depth)
      until sub.eof?
        yield sub
      end
    end

    # Skips the value of a field with the given wire type. *number* is the
    # field number, used to validate group nesting.
    def skip_field(wire_type : WireType, number : Int32) : Nil
      case wire_type
      in .varint?           then read_varint
      in .fixed64?          then read_fixed64_raw
      in .fixed32?          then read_fixed32_raw
      in .length_delimited? then read_length_delimited
      in .start_group?
        raise DecodeError.new("Recursion limit exceeded") if @depth >= DEFAULT_RECURSION_LIMIT
        @depth += 1
        loop do
          raise DecodeError.new("Unterminated group") if eof?
          inner_number, inner_type = read_tag
          if inner_type.end_group?
            raise DecodeError.new("Mismatched end group") unless inner_number == number
            break
          end
          skip_field(inner_type, inner_number)
        end
        @depth -= 1
      in .end_group?
        raise DecodeError.new("Unexpected end group")
      end
    end
  end
end
