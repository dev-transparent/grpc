require "./protobuf_helper"

private def reader(*values : Int) : Protobuf::Reader
  Protobuf::Reader.new(bytes(*values))
end

private def reader(slice : Bytes) : Protobuf::Reader
  Protobuf::Reader.new(slice)
end

private def nested_groups(depth : Int32) : Bytes
  io = IO::Memory.new
  depth.times { io.write_byte(0x0b_u8) } # field 1, start group
  depth.times { io.write_byte(0x0c_u8) } # field 1, end group
  io.to_slice
end

describe Protobuf::Writer do
  describe "varints" do
    {
                   0_u64 => "00",
                   1_u64 => "01",
                 127_u64 => "7f",
                 128_u64 => "8001",
                 150_u64 => "9601",
                 300_u64 => "ac02",
              16_383_u64 => "ff7f",
              16_384_u64 => "808001",
      UInt32::MAX.to_u64 => "ffffffff0f",
      (1_u64 << 63)      => "80808080808080808001",
      UInt64::MAX        => "ffffffffffffffffff01",
    }.each do |value, hex|
      it "encodes #{value}" do
        encode_with(&.write_varint(value)).should eq(hexbytes(hex))
        reader(hexbytes(hex)).read_varint.should eq(value)
      end
    end

    it "uses 10 bytes for UInt64::MAX" do
      encode_with(&.write_uint64(UInt64::MAX)).size.should eq(10)
    end

    it "sign extends negative int32 values to 10 bytes" do
      encode_with(&.write_int32(-1)).should eq(hexbytes("ffffffffffffffffff01"))
      encode_with(&.write_int32(Int32::MIN)).should eq(hexbytes("80808080f8ffffffff01"))
      encode_with(&.write_int64(-1_i64)).should eq(hexbytes("ffffffffffffffffff01"))
      encode_with(&.write_int64(Int64::MIN)).should eq(hexbytes("80808080808080808001"))
    end

    it "decodes int32 and int64 extremes" do
      reader(hexbytes("ffffffffffffffffff01")).read_int32.should eq(-1)
      reader(hexbytes("80808080f8ffffffff01")).read_int32.should eq(Int32::MIN)
      reader(hexbytes("ffffffff07")).read_int32.should eq(Int32::MAX)
      reader(hexbytes("80808080808080808001")).read_int64.should eq(Int64::MIN)
      reader(hexbytes("ffffffffffffffff7f")).read_int64.should eq(Int64::MAX)
    end

    it "decodes negative int32 values encoded as 5 bytes (truncating like other implementations)" do
      reader(hexbytes("ffffffff0f")).read_int32.should eq(-1)
    end

    it "truncates int32 and uint32 values wider than 32 bits" do
      reader(hexbytes("8580808010")).read_int32.should eq(5) # 2^32 + 5
      reader(hexbytes("ffffffffffffffffff01")).read_uint32.should eq(UInt32::MAX)
    end

    it "encodes uint32 values" do
      encode_with(&.write_uint32(UInt32::MAX)).should eq(hexbytes("ffffffff0f"))
      reader(hexbytes("ffffffff0f")).read_uint32.should eq(UInt32::MAX)
    end

    it "accepts non-canonical (padded) varints" do
      reader(hexbytes("8100")).read_varint.should eq(1)
      reader(hexbytes("ff80808080808080 8000")).read_varint.should eq(127)
    end

    it "decodes bools" do
      encode_with(&.write_bool(true)).should eq(bytes(1))
      encode_with(&.write_bool(false)).should eq(bytes(0))
      reader(2).read_bool.should be_true
      reader(hexbytes("ffffffffffffffffff01")).read_bool.should be_true
      reader(0).read_bool.should be_false
    end
  end

  describe "zigzag" do
    {
                   0 => 0_u64,
                  -1 => 1_u64,
                   1 => 2_u64,
                  -2 => 3_u64,
       2_147_483_647 => 4_294_967_294_u64,
      -2_147_483_648 => 4_294_967_295_u64,
    }.each do |value, encoded|
      it "encodes sint32 #{value}" do
        encode_with(&.write_sint32(value.to_i32)).should eq(encode_with(&.write_varint(encoded)))
        reader(encode_with(&.write_varint(encoded))).read_sint32.should eq(value)
      end
    end

    {
               0_i64 => 0_u64,
              -1_i64 => 1_u64,
               1_i64 => 2_u64,
      Int64::MAX     => UInt64::MAX - 1,
      Int64::MIN     => UInt64::MAX,
      -1_000_000_i64 => 1_999_999_u64,
    }.each do |value, encoded|
      it "encodes sint64 #{value}" do
        encode_with(&.write_sint64(value)).should eq(encode_with(&.write_varint(encoded)))
        reader(encode_with(&.write_varint(encoded))).read_sint64.should eq(value)
      end
    end

    it "uses 10 bytes for sint64 extremes" do
      encode_with(&.write_sint64(Int64::MIN)).should eq(hexbytes("ffffffffffffffffff01"))
      encode_with(&.write_sint64(Int64::MAX)).should eq(hexbytes("feffffffffffffffff01"))
    end
  end

  describe "fixed width" do
    it "encodes fixed32 and sfixed32 little endian" do
      encode_with(&.write_fixed32(0x12345678_u32)).should eq(hexbytes("78563412"))
      encode_with(&.write_sfixed32(-2)).should eq(hexbytes("feffffff"))
      encode_with(&.write_fixed32(UInt32::MAX)).should eq(hexbytes("ffffffff"))
      reader(hexbytes("78563412")).read_fixed32.should eq(0x12345678_u32)
      reader(hexbytes("feffffff")).read_sfixed32.should eq(-2)
      reader(hexbytes("00000080")).read_sfixed32.should eq(Int32::MIN)
    end

    it "encodes fixed64 and sfixed64 little endian" do
      encode_with(&.write_fixed64(0x0102030405060708_u64)).should eq(hexbytes("0807060504030201"))
      encode_with(&.write_sfixed64(Int64::MIN)).should eq(hexbytes("0000000000000080"))
      reader(hexbytes("0807060504030201")).read_fixed64.should eq(0x0102030405060708_u64)
      reader(hexbytes("ffffffffffffffff")).read_sfixed64.should eq(-1_i64)
      reader(hexbytes("ffffffffffffffff")).read_fixed64.should eq(UInt64::MAX)
    end

    it "encodes floats" do
      encode_with(&.write_float(1.5_f32)).should eq(hexbytes("0000c03f"))
      encode_with(&.write_float(-0.0_f32)).should eq(hexbytes("00000080"))
      encode_with(&.write_float(Float32::INFINITY)).should eq(hexbytes("0000807f"))
      encode_with(&.write_float(-Float32::INFINITY)).should eq(hexbytes("000080ff"))
      reader(hexbytes("0000c03f")).read_float.should eq(1.5_f32)
      reader(hexbytes("0000807f")).read_float.should eq(Float32::INFINITY)
      reader(hexbytes("000080ff")).read_float.should eq(-Float32::INFINITY)
      reader(hexbytes("01000000")).read_float.should eq(Float32::MIN_SUBNORMAL)
    end

    it "preserves the sign of -0.0" do
      value = reader(hexbytes("00000080")).read_float
      value.should eq(0)
      value.sign_bit.should eq(-1)
      double = reader(hexbytes("0000000000000080")).read_double
      double.should eq(0)
      double.sign_bit.should eq(-1)
    end

    it "preserves NaN payloads" do
      nan = 0x7fc00001_u32.unsafe_as(Float32)
      encoded = encode_with(&.write_float(nan))
      encoded.should eq(hexbytes("0100c07f"))
      decoded = reader(encoded).read_float
      decoded.nan?.should be_true
      decoded.unsafe_as(UInt32).should eq(0x7fc00001_u32)

      double_nan = 0x7ff8000000000123_u64.unsafe_as(Float64)
      encoded = encode_with(&.write_double(double_nan))
      reader(encoded).read_double.unsafe_as(UInt64).should eq(0x7ff8000000000123_u64)
    end

    it "encodes doubles" do
      encode_with(&.write_double(1.5)).should eq(hexbytes("000000000000f83f"))
      encode_with(&.write_double(-0.0)).should eq(hexbytes("0000000000000080"))
      encode_with(&.write_double(Float64::INFINITY)).should eq(hexbytes("000000000000f07f"))
      reader(hexbytes("000000000000f0ff")).read_double.should eq(-Float64::INFINITY)
      reader(hexbytes("ffffffffffffef7f")).read_double.should eq(Float64::MAX)
    end
  end

  describe "tags and fields" do
    it "encodes tags" do
      encode_with(&.write_tag(1, Protobuf::WireType::Varint)).should eq(bytes(0x08))
      encode_with(&.write_tag(2, Protobuf::WireType::LengthDelimited)).should eq(bytes(0x12))
      encode_with(&.write_tag(15, Protobuf::WireType::Fixed32)).should eq(bytes(0x7d))
      encode_with(&.write_tag(16, Protobuf::WireType::Varint)).should eq(bytes(0x80, 0x01))
      encode_with(&.write_tag(Protobuf::MAX_FIELD_NUMBER, Protobuf::WireType::Fixed64)).should eq(hexbytes("f9ffffff0f"))
    end

    it "decodes tags" do
      reader(0x08).read_tag.should eq({1, Protobuf::WireType::Varint})
      reader(hexbytes("f9ffffff0f")).read_tag.should eq({Protobuf::MAX_FIELD_NUMBER, Protobuf::WireType::Fixed64})
      reader(0xa3, 0x01).read_tag.should eq({20, Protobuf::WireType::StartGroup})
    end

    it "encodes complete fields" do
      encode_with(&.write_int32_field(1, 150)).should eq(hexbytes("089601"))
      encode_with(&.write_string_field(2, "testing")).should eq(hexbytes("120774657374696e67"))
      encode_with(&.write_bytes_field(3, bytes(1, 2))).should eq(hexbytes("1a020102"))
      encode_with(&.write_sint32_field(4, -1)).should eq(hexbytes("2001"))
      encode_with(&.write_fixed32_field(5, 1_u32)).should eq(hexbytes("2d01000000"))
      encode_with(&.write_double_field(6, 1.5)).should eq(hexbytes("31000000000000f83f"))
      encode_with(&.write_bool_field(7, true)).should eq(hexbytes("3801"))
    end

    it "encodes packed fields" do
      encode_with(&.write_packed_int32(4, [3, 270, 86942])).should eq(hexbytes("2206038e029ea705"))
      encode_with(&.write_packed_sint32(1, [-1, 1])).should eq(hexbytes("0a020102"))
      encode_with(&.write_packed_double(1, [1.5])).should eq(hexbytes("0a08000000000000f83f"))
      encode_with(&.write_packed_bool(1, [true, false])).should eq(hexbytes("0a020100"))
      encode_with(&.write_packed_int32(1, [-1])).should eq(hexbytes("0a0affffffffffffffffff01"))
    end

    it "omits empty packed fields" do
      encode_with(&.write_packed_int32(4, [] of Int32)).should be_empty
    end

    it "reads packed fields" do
      values = [] of Int32
      reader(hexbytes("06038e029ea705")).read_packed { |r| values << r.read_int32 }
      values.should eq([3, 270, 86942])
    end
  end

  describe "malformed input" do
    it "rejects truncated varints" do
      expect_raises(Protobuf::DecodeError, /Truncated varint/) { reader(Bytes.empty).read_varint }
      expect_raises(Protobuf::DecodeError, /Truncated varint/) { reader(0x80).read_varint }
      expect_raises(Protobuf::DecodeError, /Truncated varint/) { reader(0xff, 0xff, 0xff).read_varint }
    end

    it "drops bits beyond 64 in the tenth varint byte, like protoc and upb" do
      reader(hexbytes("ffffffffffffffffff02")).read_varint.should eq(0x7fffffffffffffff_u64)
      reader(hexbytes("ffffffffffffffffff7f")).read_varint.should eq(UInt64::MAX)
    end

    it "rejects varints longer than 10 bytes" do
      expect_raises(Protobuf::DecodeError) { reader(hexbytes("8080808080808080808001")).read_varint }
      expect_raises(Protobuf::DecodeError) { reader(hexbytes("ffffffffffffffffffff01")).read_varint }
    end

    it "rejects truncated fixed values" do
      expect_raises(Protobuf::DecodeError, /Truncated fixed32/) { reader(1, 2, 3).read_fixed32 }
      expect_raises(Protobuf::DecodeError, /Truncated fixed64/) { reader(1, 2, 3, 4, 5, 6, 7).read_fixed64 }
      expect_raises(Protobuf::DecodeError, /Truncated fixed32/) { reader(1).read_float }
      expect_raises(Protobuf::DecodeError, /Truncated fixed64/) { reader(1).read_double }
    end

    it "rejects truncated length-delimited values" do
      expect_raises(Protobuf::DecodeError, /exceeds buffer/) { reader(5, 1, 2).read_length_delimited }
      expect_raises(Protobuf::DecodeError, /exceeds buffer/) { reader(hexbytes("ffffffffffffffff7f")).read_bytes }
      expect_raises(Protobuf::DecodeError, /Truncated varint/) { reader(0x80).read_string }
    end

    it "rejects invalid wire types" do
      expect_raises(Protobuf::DecodeError, /wire type 6/) { reader(0x0e).read_tag }
      expect_raises(Protobuf::DecodeError, /wire type 7/) { reader(0x0f).read_tag }
    end

    it "rejects field number 0" do
      expect_raises(Protobuf::DecodeError, /field number 0/) { reader(0x00).read_tag }
      expect_raises(Protobuf::DecodeError, /field number 0/) { reader(0x02, 0x00).read_tag }
    end

    it "rejects tags that overflow 32 bits" do
      expect_raises(Protobuf::DecodeError, /overflows 32 bits/) { reader(hexbytes("8080808010")).read_tag }
    end

    it "rejects overlong tag varints" do
      # Field 1 / varint encoded in 9 bytes: valid as a varint, but tags
      # are limited to 5 bytes.
      expect_raises(Protobuf::DecodeError, /too long/) { reader(hexbytes("888080808080808000")).read_tag }
    end

    it "accepts the maximum field number" do
      reader(hexbytes("f8ffffff0f")).read_tag.should eq({Protobuf::MAX_FIELD_NUMBER, Protobuf::WireType::Varint})
    end

    it "rejects unexpected end groups" do
      r = reader(0x0c)
      number, wire_type = r.read_tag
      expect_raises(Protobuf::DecodeError, /Unexpected end group/) { r.skip_field(wire_type, number) }
    end
  end

  describe "#skip_field" do
    it "skips each wire type" do
      r = reader(hexbytes("08ac02 1100000000000000f0 1a03616263 1d01020304 2001"))
      4.times do
        number, wire_type = r.read_tag
        r.skip_field(wire_type, number)
      end
      r.read_tag.should eq({4, Protobuf::WireType::Varint})
      r.read_varint.should eq(1)
      r.eof?.should be_true
    end

    it "skips groups, including nested groups" do
      # field 1 start group { field 2 varint 5; field 3 group { field 4 len "a" }; field 5 fixed32 } end group 1, field 6 varint 9
      r = reader(hexbytes("0b 1005 1b 220161 1c 2d01000000 0c 3009"))
      number, wire_type = r.read_tag
      wire_type.should eq(Protobuf::WireType::StartGroup)
      r.skip_field(wire_type, number)
      r.read_tag.should eq({6, Protobuf::WireType::Varint})
      r.read_varint.should eq(9)
      r.eof?.should be_true
    end

    it "rejects mismatched end groups" do
      r = reader(0x0b, 0x14)
      number, wire_type = r.read_tag
      expect_raises(Protobuf::DecodeError, /Mismatched end group/) { r.skip_field(wire_type, number) }
    end

    it "rejects mismatched nested end groups" do
      r = reader(0x0b, 0x13, 0x0c, 0x0c)
      number, wire_type = r.read_tag
      expect_raises(Protobuf::DecodeError, /Mismatched end group/) { r.skip_field(wire_type, number) }
    end

    it "rejects unterminated groups" do
      r = reader(0x0b, 0x10, 0x01)
      number, wire_type = r.read_tag
      expect_raises(Protobuf::DecodeError, /Unterminated group/) { r.skip_field(wire_type, number) }
    end

    it "rejects truncated data inside groups" do
      r = reader(0x0b, 0x12, 0x05, 0x01)
      number, wire_type = r.read_tag
      expect_raises(Protobuf::DecodeError) { r.skip_field(wire_type, number) }
    end

    it "enforces the recursion limit for groups" do
      ok = reader(nested_groups(Protobuf::DEFAULT_RECURSION_LIMIT))
      number, wire_type = ok.read_tag
      ok.skip_field(wire_type, number)
      ok.eof?.should be_true
      ok.depth.should eq(0)

      deep = reader(nested_groups(Protobuf::DEFAULT_RECURSION_LIMIT + 1))
      number, wire_type = deep.read_tag
      expect_raises(Protobuf::DecodeError, /Recursion limit/) { deep.skip_field(wire_type, number) }
    end
  end

  describe "#read_sub_reader" do
    it "enforces the recursion limit" do
      r = Protobuf::Reader.new(bytes(0), Protobuf::DEFAULT_RECURSION_LIMIT)
      expect_raises(Protobuf::DecodeError, /Recursion limit/) { r.read_sub_reader }
      Protobuf::Reader.new(bytes(0), Protobuf::DEFAULT_RECURSION_LIMIT - 1).read_sub_reader.depth.should eq(Protobuf::DEFAULT_RECURSION_LIMIT)
    end
  end

  describe "strings" do
    it "validates UTF-8 by default" do
      reader(hexbytes("03e282ac")).read_string.should eq("€")
      reader(hexbytes("04f09f9880")).read_string.should eq("😀")
      expect_raises(Protobuf::DecodeError, /UTF-8/) { reader(hexbytes("02c328")).read_string }
      expect_raises(Protobuf::DecodeError, /UTF-8/) { reader(hexbytes("02c080")).read_string }   # overlong
      expect_raises(Protobuf::DecodeError, /UTF-8/) { reader(hexbytes("03eda080")).read_string } # surrogate
      expect_raises(Protobuf::DecodeError, /UTF-8/) { reader(hexbytes("01ff")).read_string }
    end

    it "skips validation when asked" do
      string = reader(hexbytes("02c328")).read_string(false)
      string.to_slice.should eq(bytes(0xc3, 0x28))
    end

    it "copies bytes" do
      data = hexbytes("020102")
      value = reader(data).read_bytes
      data[1] = 9_u8
      value.should eq(bytes(1, 2))
    end
  end
end

describe "Protobuf.default?" do
  it "treats zero values as defaults" do
    Protobuf.default?(0).should be_true
    Protobuf.default?(0_u64).should be_true
    Protobuf.default?("").should be_true
    Protobuf.default?(Bytes.empty).should be_true
    Protobuf.default?(false).should be_true
    Protobuf.default?(0.0).should be_true
    Protobuf.default?(0.0_f32).should be_true
    Protobuf.default?(SpecTest::Color::COLOR_UNSPECIFIED).should be_true
  end

  it "does not treat -0.0 or NaN as defaults" do
    Protobuf.default?(-0.0).should be_false
    Protobuf.default?(-0.0_f32).should be_false
    Protobuf.default?(Float64::NAN).should be_false
    Protobuf.default?(1).should be_false
    Protobuf.default?(SpecTest::Color::NEGATIVE).should be_false
  end
end
