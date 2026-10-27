require "./protobuf_helper"

# Hand-written messages exercising DSL options directly.
class SpecTypeOverrides
  include Protobuf::Message

  field s32 : Int32, 1, type: :sint32
  field s64 : Int64, 2, type: :sint64
  field f32 : UInt32, 3, type: :fixed32
  field f64 : UInt64, 4, type: :fixed64
  field sf32 : Int32, 5, type: :sfixed32
  field sf64 : Int64, 6, type: :sfixed64
  repeated rs32 : Int32, 7, type: :sint32
  repeated rsf64 : Int64, 8, type: :sfixed64, packed: false
  map m : Hash(Int32, Int64), 9, key_type: :sint32, value_type: :sfixed64
  field with_default : Int32, 10, default: 7
  field raw : String, 11, utf8: false
  repeated raws : String, 12, utf8: false
  map raw_map : Hash(String, String), 13, utf8: false
  field optional_s32 : Int32, 14, type: :sint32, optional: true
end

class SpecDeclaredLater
  include Protobuf::Message

  # Refers to a type declared after this class.
  field later : SpecLater, 1
  repeated laters : SpecLater, 2
end

class SpecLater
  include Protobuf::Message

  field value : Int32, 1
end

class SpecEmptyMessage
  include Protobuf::Message
end

private def scalars_bytes : Bytes
  SpecTest::Scalars.new(
    int32_value: -5, int64_value: 1_i64 << 40, uint32_value: 7_u32, uint64_value: UInt64::MAX,
    sint32_value: -3, sint64_value: Int64::MIN, fixed32_value: 9_u32, fixed64_value: 10_u64,
    sfixed32_value: -11, sfixed64_value: -12_i64, float_value: 1.5_f32, double_value: -2.25,
    bool_value: true, string_value: "héllo", bytes_value: bytes(0, 255), color: SpecTest::Color::GREEN,
  ).to_protobuf
end

describe Protobuf::Message do
  describe "proto3 implicit presence" do
    it "does not serialize default values" do
      SpecTest::Scalars.new.to_protobuf.should be_empty
      SpecTest::Scalars.new(int32_value: 0, string_value: "", bytes_value: Bytes.empty, bool_value: false,
        double_value: 0.0, float_value: 0.0_f32, color: SpecTest::Color::COLOR_UNSPECIFIED).to_protobuf.should be_empty
    end

    it "has zero-value defaults" do
      message = SpecTest::Scalars.new
      message.int32_value.should eq(0)
      message.uint64_value.should eq(0_u64)
      message.string_value.should eq("")
      message.bytes_value.should eq(Bytes.empty)
      message.bool_value.should be_false
      message.double_value.should eq(0.0)
      message.color.should eq(SpecTest::Color::COLOR_UNSPECIFIED)
    end

    it "serializes -0.0" do
      SpecTest::Scalars.new(double_value: -0.0).to_protobuf.should eq(hexbytes("610000000000000080"))
      SpecTest::Scalars.new(float_value: -0.0_f32).to_protobuf.should eq(hexbytes("5d00000080"))
      SpecTest::Scalars.from_protobuf(hexbytes("610000000000000080")).double_value.sign_bit.should eq(-1)
    end

    it "serializes NaN" do
      message = SpecTest::Scalars.from_protobuf(SpecTest::Scalars.new(double_value: Float64::NAN).to_protobuf)
      message.double_value.nan?.should be_true
    end

    it "encodes each scalar type" do
      {
        SpecTest::Scalars.new(int32_value: 150)                 => "089601",
        SpecTest::Scalars.new(int32_value: -1)                  => "08ffffffffffffffffff01",
        SpecTest::Scalars.new(int64_value: -2_i64)              => "10feffffffffffffffff01",
        SpecTest::Scalars.new(uint32_value: UInt32::MAX)        => "18ffffffff0f",
        SpecTest::Scalars.new(uint64_value: UInt64::MAX)        => "20ffffffffffffffffff01",
        SpecTest::Scalars.new(sint32_value: -1)                 => "2801",
        SpecTest::Scalars.new(sint32_value: Int32::MIN)         => "28ffffffff0f",
        SpecTest::Scalars.new(sint64_value: Int64::MAX)         => "30feffffffffffffffff01",
        SpecTest::Scalars.new(fixed32_value: 1_u32)             => "3d01000000",
        SpecTest::Scalars.new(fixed64_value: UInt64::MAX)       => "41ffffffffffffffff",
        SpecTest::Scalars.new(sfixed32_value: -1)               => "4dffffffff",
        SpecTest::Scalars.new(sfixed64_value: Int64::MIN)       => "510000000000000080",
        SpecTest::Scalars.new(float_value: Float32::INFINITY)   => "5d0000807f",
        SpecTest::Scalars.new(double_value: 1.0)                => "61000000000000f03f",
        SpecTest::Scalars.new(bool_value: true)                 => "6801",
        SpecTest::Scalars.new(string_value: "hi")               => "72026869",
        SpecTest::Scalars.new(bytes_value: bytes(0, 1))         => "7a020001",
        SpecTest::Scalars.new(color: SpecTest::Color::RED)      => "800101",
        SpecTest::Scalars.new(color: SpecTest::Color::NEGATIVE) => "8001ffffffffffffffffff01",
      }.each do |message, hex|
        message.to_protobuf.should eq(hexbytes(hex))
        SpecTest::Scalars.from_protobuf(hexbytes(hex)).should eq(message)
      end
    end

    it "serializes fields in field number order and round trips" do
      encoded = scalars_bytes
      decoded = SpecTest::Scalars.from_protobuf(encoded)
      decoded.to_protobuf.should eq(encoded)
      decoded.uint64_value.should eq(UInt64::MAX)
      decoded.sint64_value.should eq(Int64::MIN)
      decoded.string_value.should eq("héllo")
      decoded.bytes_value.should eq(bytes(0, 255))
      tags = [] of Int32
      reader = Protobuf::Reader.new(encoded)
      until reader.eof?
        number, wire_type = reader.read_tag
        tags << number
        reader.skip_field(wire_type, number)
      end
      tags.should eq((1..16).to_a)
    end

    it "decodes fields in any order, last value wins" do
      message = SpecTest::Scalars.from_protobuf(hexbytes("7202 6869 0801 7201 61 0802"))
      message.int32_value.should eq(2)
      message.string_value.should eq("a")
    end

    it "parses from an IO" do
      SpecTest::Scalars.from_protobuf(IO::Memory.new(hexbytes("0805"))).int32_value.should eq(5)
      io = IO::Memory.new
      SpecTest::Scalars.new(int32_value: 5).to_protobuf(io)
      io.to_slice.should eq(hexbytes("0805"))
    end
  end

  describe "explicit presence" do
    it "uses nil for unset optional fields" do
      message = SpecTest::Optionals.new
      message.int32_value.should be_nil
      message.string_value.should be_nil
      message.color.should be_nil
      message.message_value.should be_nil
      message.to_protobuf.should be_empty
    end

    it "serializes default values when set" do
      message = SpecTest::Optionals.new(int32_value: 0, string_value: "", color: SpecTest::Color::COLOR_UNSPECIFIED, double_value: 0.0)
      message.to_protobuf.should eq(hexbytes("0800 1200 1800 210000000000000000"))
      decoded = SpecTest::Optionals.from_protobuf(message.to_protobuf)
      decoded.int32_value.should eq(0)
      decoded.string_value.should eq("")
      decoded.color.should eq(SpecTest::Color::COLOR_UNSPECIFIED)
      decoded.double_value.should eq(0.0)
      decoded.should eq(message)
    end

    it "tracks presence of message fields" do
      message = SpecTest::Optionals.new(message_value: SpecTest::Scalars.new)
      message.to_protobuf.should eq(hexbytes("2a00"))
      SpecTest::Optionals.from_protobuf(hexbytes("2a00")).message_value.should eq(SpecTest::Scalars.new)
      SpecTest::Optionals.from_protobuf(Bytes.empty).message_value.should be_nil
    end

    it "can be cleared by assigning nil" do
      message = SpecTest::Optionals.new(int32_value: 3)
      message.int32_value = nil
      message.to_protobuf.should be_empty
    end

    it "applies to proto2 fields" do
      message = SpecTest::Proto2::Legacy.new(value: 0, name: "")
      message.to_protobuf.should eq(hexbytes("0800 1200"))
      SpecTest::Proto2::Legacy.from_protobuf(hexbytes("0800")).value.should eq(0)
      SpecTest::Proto2::Legacy.from_protobuf(Bytes.empty).value.should be_nil
    end
  end

  describe "repeated fields" do
    it "packs scalar fields by default" do
      SpecTest::Repeateds.new(int32_values: [1, 2, 300]).to_protobuf.should eq(hexbytes("0a04 0102ac02"))
      SpecTest::Repeateds.new(sint64_values: [-1_i64, 1_i64]).to_protobuf.should eq(hexbytes("1202 0102"))
      SpecTest::Repeateds.new(fixed32_values: [1_u32, 2_u32]).to_protobuf.should eq(hexbytes("1a08 01000000 02000000"))
      SpecTest::Repeateds.new(double_values: [1.0]).to_protobuf.should eq(hexbytes("2208 000000000000f03f"))
      SpecTest::Repeateds.new(bool_values: [true, false]).to_protobuf.should eq(hexbytes("2a02 0100"))
      SpecTest::Repeateds.new(colors: [SpecTest::Color::RED, SpecTest::Color::NEGATIVE]).to_protobuf
        .should eq(hexbytes("320b 01 ffffffffffffffffff01"))
    end

    it "keeps default values in repeated fields" do
      SpecTest::Repeateds.new(int32_values: [0, 0]).to_protobuf.should eq(hexbytes("0a02 0000"))
      SpecTest::Repeateds.new(strings: ["", ""]).to_protobuf.should eq(hexbytes("3a00 3a00"))
    end

    it "writes unpacked fields as one record per element" do
      SpecTest::Repeateds.new(unpacked_int32_values: [1, 2]).to_protobuf.should eq(hexbytes("5001 5002"))
      SpecTest::Repeateds.new(strings: ["a", "b"]).to_protobuf.should eq(hexbytes("3a0161 3a0162"))
      SpecTest::Repeateds.new(bytes_values: [bytes(1)]).to_protobuf.should eq(hexbytes("420101"))
      SpecTest::Repeateds.new(messages: [SpecTest::Scalars.new(int32_value: 1), SpecTest::Scalars.new])
        .to_protobuf.should eq(hexbytes("4a020801 4a00"))
    end

    it "writes nothing for empty repeated fields" do
      SpecTest::Repeateds.new.to_protobuf.should be_empty
    end

    it "decodes both packed and unpacked encodings regardless of declaration" do
      SpecTest::Repeateds.from_protobuf(hexbytes("0801 0802 0a02 0304 0805")).int32_values.should eq([1, 2, 3, 4, 5])
      SpecTest::Repeateds.from_protobuf(hexbytes("5203 010203 5004")).unpacked_int32_values.should eq([1, 2, 3, 4])
      SpecTest::Repeateds.from_protobuf(hexbytes("1d01000000 1a04 02000000")).fixed32_values.should eq([1_u32, 2_u32])
      SpecTest::Repeateds.from_protobuf(hexbytes("21000000000000f03f")).double_values.should eq([1.0])
      SpecTest::Repeateds.from_protobuf(hexbytes("3001 3202 0205")).colors
        .should eq([SpecTest::Color::RED, SpecTest::Color::GREEN, SpecTest::Color.new(5)])
      SpecTest::Repeateds.from_protobuf(hexbytes("2801 2a01 00")).bool_values.should eq([true, false])
    end

    it "decodes empty packed payloads" do
      SpecTest::Repeateds.from_protobuf(hexbytes("0a00")).int32_values.should be_empty
    end

    it "decodes packed and unpacked proto2 fields" do
      message = SpecTest::Proto2::Legacy.from_protobuf(hexbytes("1801 1a02 0203 2203 040506 2007"))
      message.values.should eq([1, 2, 3])
      message.packed_values.should eq([4, 5, 6, 7])
      SpecTest::Proto2::Legacy.new(values: [1, 2], packed_values: [3]).to_protobuf.should eq(hexbytes("1801 1802 2201 03"))
    end

    it "rejects truncated packed payloads" do
      expect_raises(Protobuf::DecodeError) { SpecTest::Repeateds.from_protobuf(hexbytes("1a03 010000")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Repeateds.from_protobuf(hexbytes("0a02 80")) }
    end

    it "keeps elements with the wrong wire type as unknown fields" do
      message = SpecTest::Repeateds.from_protobuf(hexbytes("0d01000000 0801"))
      message.int32_values.should eq([1])
      message.unknown_fields.should eq(hexbytes("0d01000000"))
    end

    it "appends when decoding repeated occurrences" do
      message = SpecTest::Repeateds.from_protobuf(hexbytes("3a0161 4a020801 3a0162 4a020802"))
      message.strings.should eq(["a", "b"])
      message.messages.map(&.int32_value).should eq([1, 2])
    end
  end

  describe "map fields" do
    it "encodes entries with key and value" do
      SpecTest::Maps.new(int32_to_string: {1 => "a"}).to_protobuf.should eq(hexbytes("0a05 0801 120161"))
      SpecTest::Maps.new(sint32_to_sint32: {-1 => -2}).to_protobuf.should eq(hexbytes("2a04 0801 1003"))
      SpecTest::Maps.new(fixed64_to_fixed64: {1_u64 => 2_u64}).to_protobuf
        .should eq(hexbytes("4212 090100000000000000 110200000000000000"))
      SpecTest::Maps.new(bool_to_bool: {false => false}).to_protobuf.should eq(hexbytes("5a04 0800 1000"))
      SpecTest::Maps.new(string_to_message: {"k" => SpecTest::Scalars.new}).to_protobuf.should eq(hexbytes("6a05 0a016b 1200"))
      SpecTest::Maps.new(string_to_color: {"k" => SpecTest::Color::RED}).to_protobuf.should eq(hexbytes("7205 0a016b 1001"))
    end

    it "round trips every key kind" do
      message = SpecTest::Maps.new(
        int32_to_string: {Int32::MIN => "min", 0 => "", Int32::MAX => "max"},
        int64_to_int64: {Int64::MIN => Int64::MAX, -1_i64 => 1_i64},
        uint32_to_uint32: {UInt32::MAX => 0_u32},
        uint64_to_uint64: {UInt64::MAX => 1_u64},
        sint32_to_sint32: {Int32::MIN => Int32::MAX},
        sint64_to_sint64: {Int64::MIN => Int64::MAX},
        fixed32_to_fixed32: {UInt32::MAX => 1_u32},
        fixed64_to_fixed64: {UInt64::MAX => 2_u64},
        sfixed32_to_sfixed32: {-1 => Int32::MIN},
        sfixed64_to_sfixed64: {-1_i64 => Int64::MIN},
        bool_to_bool: {true => false, false => true},
        string_to_bytes: {"a" => bytes(1), "" => Bytes.empty},
        string_to_message: {"m" => SpecTest::Scalars.new(int32_value: 4)},
        string_to_color: {"c" => SpecTest::Color::NEGATIVE, "u" => SpecTest::Color.new(99)},
        string_to_double: {"neg" => -0.0, "inf" => Float64::INFINITY},
      )
      decoded = SpecTest::Maps.from_protobuf(message.to_protobuf)
      decoded.should eq(message)
      decoded.to_protobuf.should eq(message.to_protobuf)
      decoded.string_to_double["neg"].sign_bit.should eq(-1)
      decoded.string_to_color["u"].value.should eq(99)
    end

    it "uses defaults for missing keys and values" do
      SpecTest::Maps.from_protobuf(hexbytes("0a00")).int32_to_string.should eq({0 => ""})
      SpecTest::Maps.from_protobuf(hexbytes("0a02 0805")).int32_to_string.should eq({5 => ""})
      SpecTest::Maps.from_protobuf(hexbytes("0a03 120161")).int32_to_string.should eq({0 => "a"})
      SpecTest::Maps.from_protobuf(hexbytes("6a03 0a016b")).string_to_message.should eq({"k" => SpecTest::Scalars.new})
      SpecTest::Maps.from_protobuf(hexbytes("7203 0a016b")).string_to_color.should eq({"k" => SpecTest::Color::COLOR_UNSPECIFIED})
      SpecTest::Maps.from_protobuf(hexbytes("5a00")).bool_to_bool.should eq({false => false})
    end

    it "accepts entries with fields in any order and skips unknown entry fields" do
      SpecTest::Maps.from_protobuf(hexbytes("0a07 120161 1801 0802")).int32_to_string.should eq({2 => "a"})
    end

    it "keeps the last value for duplicate keys" do
      message = SpecTest::Maps.from_protobuf(hexbytes("0a05 0801 120161 0a05 0802 120162 0a05 0801 120163"))
      message.int32_to_string.should eq({1 => "c", 2 => "b"})
    end

    it "uses the last key and value within an entry" do
      SpecTest::Maps.from_protobuf(hexbytes("0a0a 0801 120161 0802 120162")).int32_to_string.should eq({2 => "b"})
    end

    it "merges repeated message values within an entry" do
      message = SpecTest::Maps.from_protobuf(hexbytes("6a0b 0a016b 12020801 12021005"))
      message.string_to_message["k"].should eq(SpecTest::Scalars.new(int32_value: 1, int64_value: 5_i64))
    end

    it "ignores entry fields with an unexpected wire type" do
      SpecTest::Maps.from_protobuf(hexbytes("0a07 0d01000000 0803")).int32_to_string.should eq({3 => ""})
    end

    it "treats a map field with the wrong wire type as unknown" do
      message = SpecTest::Maps.from_protobuf(hexbytes("0801"))
      message.int32_to_string.should be_empty
      message.unknown_fields.should eq(hexbytes("0801"))
    end

    it "rejects truncated entries" do
      expect_raises(Protobuf::DecodeError) { SpecTest::Maps.from_protobuf(hexbytes("0a03 0801 12")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Maps.from_protobuf(hexbytes("0a05 0801")) }
    end

    it "validates UTF-8 in string keys and values" do
      expect_raises(Protobuf::DecodeError, /UTF-8/) { SpecTest::Maps.from_protobuf(hexbytes("6204 0a02c328")) }
      expect_raises(Protobuf::DecodeError, /UTF-8/) { SpecTest::Maps.from_protobuf(hexbytes("0a04 1202c328")) }
    end
  end

  describe "oneof" do
    it "is empty by default" do
      choice = SpecTest::Choice.new
      choice.value.should be_nil
      choice.value_case.should be_nil
      choice.to_protobuf.should be_empty
    end

    it "clears the other members when one is set" do
      choice = SpecTest::Choice.new
      choice.name = "a"
      choice.value_case.should eq(:name)
      choice.value.should eq("a")
      choice.number = 5
      choice.name.should be_nil
      choice.number.should eq(5)
      choice.value_case.should eq(:number)
      choice.message = SpecTest::Scalars.new
      choice.number.should be_nil
      choice.value_case.should eq(:message)
      choice.color = SpecTest::Color::RED
      choice.message.should be_nil
      choice.value.should eq(SpecTest::Color::RED)
    end

    it "does not clear other members when a member is set to nil" do
      choice = SpecTest::Choice.new
      choice.number = 1
      choice.name = nil
      choice.number.should eq(1)
    end

    it "clears the oneof" do
      choice = SpecTest::Choice.new
      choice.data = bytes(1)
      choice.clear_value
      choice.value_case.should be_nil
      choice.data.should be_nil
      choice.to_protobuf.should be_empty
    end

    it "serializes default values of the set member" do
      SpecTest::Choice.new(number: 0).to_protobuf.should eq(hexbytes("1000"))
      SpecTest::Choice.new(name: "").to_protobuf.should eq(hexbytes("0a00"))
      SpecTest::Choice.new(message: SpecTest::Scalars.new).to_protobuf.should eq(hexbytes("1a00"))
      SpecTest::Choice.new(color: SpecTest::Color::COLOR_UNSPECIFIED).to_protobuf.should eq(hexbytes("2000"))
      SpecTest::Choice.from_protobuf(hexbytes("1000")).value_case.should eq(:number)
      SpecTest::Choice.from_protobuf(hexbytes("0a00")).name.should eq("")
    end

    it "uses the last member on the wire" do
      choice = SpecTest::Choice.from_protobuf(hexbytes("0a0161 1005 3007"))
      choice.value_case.should eq(:number)
      choice.name.should be_nil
      choice.number.should eq(5)
      choice.other.should eq(7)
      choice.to_protobuf.should eq(hexbytes("1005 3007"))

      choice = SpecTest::Choice.from_protobuf(hexbytes("1005 1a020801 0a0162"))
      choice.value_case.should eq(:name)
      choice.message.should be_nil
    end

    it "merges a message member repeated on the wire" do
      choice = SpecTest::Choice.from_protobuf(hexbytes("1a020801 1a021002"))
      choice.message.should eq(SpecTest::Scalars.new(int32_value: 1, int64_value: 2_i64))
    end

    it "replaces a message member after a different member" do
      choice = SpecTest::Choice.from_protobuf(hexbytes("1a020801 1005 1a021002"))
      choice.message.should eq(SpecTest::Scalars.new(int64_value: 2_i64))
    end

    it "is generated for well-known types" do
      value = Google::Protobuf::Value.new(string_value: "x")
      value.kind_case.should eq(:string_value)
      value.number_value = 1.0
      value.kind.should eq(1.0)
      Google::Protobuf::Value.from_protobuf(value.to_protobuf).should eq(value)
    end
  end

  describe "merging" do
    it "replaces singular scalars and appends repeated fields" do
      message = SpecTest::Repeateds.new(int32_values: [1])
      message.merge_from(SpecTest::Repeateds.new(int32_values: [2], strings: ["x"]))
      message.int32_values.should eq([1, 2])
      message.strings.should eq(["x"])

      scalars = SpecTest::Scalars.new(int32_value: 1, string_value: "keep")
      scalars.merge_from(SpecTest::Scalars.new(int32_value: 2))
      scalars.int32_value.should eq(2)
      scalars.string_value.should eq("keep")
    end

    it "merges singular message fields recursively" do
      first = SpecTest::Outer.new(middle: SpecTest::Outer::Middle.new(inner: SpecTest::Outer::Middle::Inner.new(text: "a")), kind: SpecTest::Outer::Kind::KIND_A)
      second = SpecTest::Outer.new(middle: SpecTest::Outer::Middle.new(
        inner: SpecTest::Outer::Middle::Inner.new(kind: SpecTest::Outer::Kind::KIND_A),
        inners: [SpecTest::Outer::Middle::Inner.new(text: "b")]))
      decoded = SpecTest::Outer.from_protobuf(first.to_protobuf + second.to_protobuf)
      decoded.middle.should eq(SpecTest::Outer::Middle.new(
        inner: SpecTest::Outer::Middle::Inner.new(text: "a", kind: SpecTest::Outer::Kind::KIND_A),
        inners: [SpecTest::Outer::Middle::Inner.new(text: "b")]))
      decoded.kind.should eq(SpecTest::Outer::Kind::KIND_A)

      first.merge_from(second)
      first.should eq(decoded)
    end

    it "merges nested fields split across records" do
      # middle { inner { text: "a" } } then middle { inner { text: "b" } inners { } }
      decoded = SpecTest::Outer.from_protobuf(hexbytes("0a05 0a03 0a0161 0a07 0a03 0a0162 1200"))
      middle = decoded.middle.not_nil!
      middle.inner.not_nil!.text.should eq("b")
      middle.inners.size.should eq(1)
    end

    it "merges into an existing message with merge_from_protobuf" do
      message = SpecTest::Scalars.new(int32_value: 1, int64_value: 2_i64)
      message.merge_from_protobuf(Protobuf::Reader.new(hexbytes("0803")))
      message.should eq(SpecTest::Scalars.new(int32_value: 3, int64_value: 2_i64))
    end

    it "merges well-known type fields" do
      a = SpecTest::Outer.new(created_at: Google::Protobuf::Timestamp.new(seconds: 5_i64))
      a.merge_from(SpecTest::Outer.new(created_at: Google::Protobuf::Timestamp.new(nanos: 7)))
      a.created_at.should eq(Google::Protobuf::Timestamp.new(seconds: 5_i64, nanos: 7))
    end
  end

  describe "unknown fields" do
    it "preserves unknown fields byte for byte" do
      encoded = scalars_bytes
      subset = SpecTest::ScalarsSubset.from_protobuf(encoded)
      subset.int32_value.should eq(-5)
      subset.unknown_fields.should eq(encoded[11..]) # after field 1 (1 + 10 bytes)
      subset.to_protobuf.should eq(encoded)
      SpecTest::Scalars.from_protobuf(subset.to_protobuf).should eq(SpecTest::Scalars.from_protobuf(encoded))
    end

    it "preserves every wire type, including groups" do
      data = hexbytes("10ac02 1900000000000000f0 2a03616263 2d01020304 33 3801 3b 4801 3c 34 a00601")
      message = SpecTest::Empty.from_protobuf(data)
      message.unknown_fields.should eq(data)
      message.to_protobuf.should eq(data)
    end

    it "emits unknown fields after known fields" do
      message = SpecTest::ScalarsSubset.from_protobuf(hexbytes("1001 0805"))
      message.unknown_fields.should eq(hexbytes("1001"))
      message.to_protobuf.should eq(hexbytes("0805 1001"))
    end

    it "preserves unknown fields in nested messages" do
      wrapper = SpecTest::Sub::Wrapper.from_protobuf(hexbytes("0a05 0801 f801 01"))
      wrapper.scalars.not_nil!.unknown_fields.should eq(hexbytes("f80101"))
      wrapper.to_protobuf.should eq(hexbytes("0a05 0801 f801 01"))
    end

    it "keeps known fields with an unexpected wire type as unknown" do
      message = SpecTest::Scalars.from_protobuf(hexbytes("0d01000000 0a00"))
      message.int32_value.should eq(0)
      message.unknown_fields.should eq(hexbytes("0d01000000 0a00"))
      message.to_protobuf.should eq(hexbytes("0d01000000 0a00"))
    end

    it "discards unknown fields" do
      message = SpecTest::Empty.from_protobuf(hexbytes("0801"))
      message.discard_unknown_fields
      message.unknown_fields.should be_empty
      message.to_protobuf.should be_empty
    end

    it "is considered by == and preserved by clone" do
      a = SpecTest::Empty.from_protobuf(hexbytes("0801"))
      b = SpecTest::Empty.from_protobuf(hexbytes("0802"))
      a.should_not eq(b)
      a.should eq(SpecTest::Empty.from_protobuf(hexbytes("0801")))
      a.clone.unknown_fields.should eq(hexbytes("0801"))
    end

    it "rejects malformed unknown fields" do
      expect_raises(Protobuf::DecodeError) { SpecTest::Empty.from_protobuf(hexbytes("0e")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Empty.from_protobuf(hexbytes("0f")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Empty.from_protobuf(hexbytes("00")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Empty.from_protobuf(hexbytes("0c")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Empty.from_protobuf(hexbytes("0b 14")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Empty.from_protobuf(hexbytes("0b 1001")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Empty.from_protobuf(hexbytes("1205 01")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Empty.from_protobuf(hexbytes("19 0102")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Empty.from_protobuf(hexbytes("08 80")) }
    end

    it "rejects malformed known fields" do
      expect_raises(Protobuf::DecodeError) { SpecTest::Scalars.from_protobuf(hexbytes("08")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Scalars.from_protobuf(hexbytes("3d 0100")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Scalars.from_protobuf(hexbytes("41 0100")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Scalars.from_protobuf(hexbytes("7203 6869")) }
      expect_raises(Protobuf::DecodeError) { SpecTest::Optionals.from_protobuf(hexbytes("2a02 08")) }
    end
  end

  describe "recursion limit" do
    it "accepts nesting up to the limit and rejects deeper nesting" do
      build = ->(depth : Int32) do
        bytes = Bytes.empty
        depth.times do
          io = IO::Memory.new
          Protobuf::Writer.new(io).write_bytes_field(2, bytes) # Outer.child
          bytes = io.to_slice
        end
        bytes
      end
      message = SpecTest::Outer.from_protobuf(build.call(Protobuf::DEFAULT_RECURSION_LIMIT))
      depth = 0
      current = message
      while child = current.child
        depth += 1
        current = child
      end
      depth.should eq(Protobuf::DEFAULT_RECURSION_LIMIT)
      expect_raises(Protobuf::DecodeError, /Recursion limit/) do
        SpecTest::Outer.from_protobuf(build.call(Protobuf::DEFAULT_RECURSION_LIMIT + 1))
      end
    end
  end

  describe "open enums" do
    it "preserves unknown enum values" do
      message = SpecTest::Scalars.from_protobuf(hexbytes("8001 63"))
      message.color.value.should eq(99)
      message.unknown_fields.should be_empty
      message.to_protobuf.should eq(hexbytes("800163"))
    end

    it "preserves unknown negative enum values" do
      message = SpecTest::Scalars.from_protobuf(hexbytes("8001 feffffffffffffffff01"))
      message.color.value.should eq(-2)
      message.to_protobuf.should eq(hexbytes("8001 feffffffffffffffff01"))
    end

    it "preserves unknown values in repeated and map fields" do
      repeated = SpecTest::Repeateds.from_protobuf(hexbytes("3202 0763"))
      repeated.colors.map(&.value).should eq([7, 99])
      repeated.to_protobuf.should eq(hexbytes("3202 0763"))

      map = SpecTest::Maps.from_protobuf(hexbytes("7205 0a016b 1009"))
      map.string_to_color["k"].value.should eq(9)
      map.to_protobuf.should eq(hexbytes("7205 0a016b 1009"))
    end
  end

  describe "UTF-8 validation" do
    it "rejects invalid UTF-8 in proto3 strings" do
      expect_raises(Protobuf::DecodeError, /UTF-8/) { SpecTest::Scalars.from_protobuf(hexbytes("7202 c328")) }
      expect_raises(Protobuf::DecodeError, /UTF-8/) { SpecTest::Repeateds.from_protobuf(hexbytes("3a02 c328")) }
      expect_raises(Protobuf::DecodeError, /UTF-8/) { SpecTest::Choice.from_protobuf(hexbytes("0a01 80")) }
      expect_raises(Protobuf::DecodeError, /UTF-8/) { SpecTest::Scalars.from_protobuf(hexbytes("7203 eda080")) }
    end

    it "does not validate bytes fields" do
      SpecTest::Scalars.from_protobuf(hexbytes("7a02 c328")).bytes_value.should eq(bytes(0xc3, 0x28))
    end

    it "accepts any bytes in utf8: false strings and round trips them" do
      message = SpecTest::Proto2::Legacy.from_protobuf(hexbytes("2a02 c328"))
      message.text.not_nil!.to_slice.should eq(bytes(0xc3, 0x28))
      message.to_protobuf.should eq(hexbytes("2a02 c328"))

      overrides = SpecTypeOverrides.from_protobuf(hexbytes("5a01ff 6201fe 6a06 0a01ff 1201fe"))
      overrides.raw.to_slice.should eq(bytes(0xff))
      overrides.raws.map(&.to_slice).should eq([bytes(0xfe)])
      overrides.raw_map.size.should eq(1)
      # with_default is not a proto default, so it is serialized.
      overrides.to_protobuf.should eq(hexbytes("5007 5a01ff 6201fe 6a06 0a01ff 1201fe"))
    end

    it "follows editions utf8_validation features" do
      SpecTest::Editions::EditionsMessage.from_protobuf(hexbytes("3a01ff")).unchecked_text.not_nil!.bytesize.should eq(1)
      SpecTest::Editions::EditionsMessage.from_protobuf(hexbytes("4201ff")).unchecked_texts.size.should eq(1)
      expect_raises(Protobuf::DecodeError, /UTF-8/) { SpecTest::Editions::EditionsMessage.from_protobuf(hexbytes("3201ff")) }
      SpecTest::Editions::ImplicitMessage.from_protobuf(hexbytes("1a01ff")).text.bytesize.should eq(1)
      SpecTest::Editions::ImplicitMessage.from_protobuf(hexbytes("2206 0a01ff 1201fe")).labels.size.should eq(1)
      expect_raises(Protobuf::DecodeError, /UTF-8/) { SpecTest::Editions::ImplicitMessage.from_protobuf(hexbytes("3a01ff")) }
    end
  end

  describe "editions" do
    it "uses explicit presence by default and implicit presence when requested" do
      SpecTest::Editions::EditionsMessage.new(explicit_value: 0, implicit_value: 0).to_protobuf.should eq(hexbytes("0800"))
      SpecTest::Editions::EditionsMessage.new.explicit_value.should be_nil
      SpecTest::Editions::ImplicitMessage.new(value: 0, explicit_value: 0).to_protobuf.should eq(hexbytes("2800"))
    end

    it "packs by default and expands when requested" do
      SpecTest::Editions::EditionsMessage.new(packed_values: [1, 2], expanded_values: [3, 4]).to_protobuf
        .should eq(hexbytes("2202 0102 2803 2804"))
      SpecTest::Editions::ImplicitMessage.new(values: [1, 2], packed_values: [3]).to_protobuf
        .should eq(hexbytes("1001 1002 3201 03"))
    end

    it "decodes delimited (group-encoded) message fields" do
      data = hexbytes("53 0805 54")
      message = SpecTest::Editions::EditionsMessage.from_protobuf(data)
      message.delimited_child.should_not be_nil
      message.unknown_fields.should be_empty
      message.to_protobuf.should eq(data)
    end

    it "keeps a delimited field sent length-prefixed as an unknown field" do
      data = hexbytes("52 02 0805")
      message = SpecTest::Editions::EditionsMessage.from_protobuf(data)
      message.delimited_child.should be_nil
      message.unknown_fields.should eq(data)
    end
  end

  describe "proto2 groups" do
    it "decodes groups as message fields and round trips them" do
      data = hexbytes("0801 1201 61 33 3805 34 4002")
      message = SpecTest::Proto2::Legacy.from_protobuf(data)
      message.value.should eq(1)
      message.name.should eq("a")
      message.with_default.should eq(2)
      message.settings.should eq(SpecTest::Proto2::Legacy::Settings.new(level: 5))
      message.unknown_fields.should be_empty
      message.to_protobuf.should eq(data)
      SpecTest::Proto2::Legacy.from_protobuf(message.to_protobuf).should eq(message)
    end

    it "merges repeated occurrences of a group" do
      message = SpecTest::Proto2::Legacy.from_protobuf(hexbytes("33 3805 34 33 34"))
      message.settings.should eq(SpecTest::Proto2::Legacy::Settings.new(level: 5))
    end

    it "rejects unterminated and mismatched groups" do
      expect_raises(Protobuf::DecodeError, /Unterminated group/) { SpecTest::Proto2::Legacy.from_protobuf(hexbytes("33 3805")) }
      expect_raises(Protobuf::DecodeError, /Mismatched end group/) { SpecTest::Proto2::Legacy.from_protobuf(hexbytes("33 3805 3c")) }
      expect_raises(Protobuf::DecodeError, /Mismatched end group/) { SpecTest::Proto2::Legacy.from_protobuf(hexbytes("34")) }
    end

    it "keeps a group sent with the wrong wire type as an unknown field" do
      data = hexbytes("32 02 3805")
      message = SpecTest::Proto2::Legacy.from_protobuf(data)
      message.settings.should be_nil
      message.unknown_fields.should eq(data)
    end
  end

  describe "==, hash and clone" do
    it "compares field values" do
      a = SpecTest::Scalars.from_protobuf(scalars_bytes)
      b = SpecTest::Scalars.from_protobuf(scalars_bytes)
      a.should eq(b)
      a.hash.should eq(b.hash)
      b.int32_value = 1
      a.should_not eq(b)
      SpecTest::Optionals.new(int32_value: 0).should_not eq(SpecTest::Optionals.new)
      SpecTest::Optionals.new(message_value: SpecTest::Scalars.new).should_not eq(SpecTest::Optionals.new)
    end

    it "compares repeated, map and oneof fields" do
      SpecTest::Repeateds.new(int32_values: [1, 2]).should_not eq(SpecTest::Repeateds.new(int32_values: [2, 1]))
      SpecTest::Maps.new(int32_to_string: {1 => "a", 2 => "b"}).should eq(SpecTest::Maps.new(int32_to_string: {2 => "b", 1 => "a"}))
      SpecTest::Choice.new(number: 0).should_not eq(SpecTest::Choice.new)
      SpecTest::Choice.new(name: "a").should eq(SpecTest::Choice.new(name: "a"))
    end

    it "can be used as hash keys" do
      set = Set{SpecTest::Scalars.new(int32_value: 1), SpecTest::Scalars.new(int32_value: 1), SpecTest::Scalars.new(int32_value: 2)}
      set.size.should eq(2)
      set.includes?(SpecTest::Scalars.from_protobuf(hexbytes("0801"))).should be_true
    end

    it "clones deeply" do
      original = SpecTest::Outer.new(
        middle: SpecTest::Outer::Middle.new(inner: SpecTest::Outer::Middle::Inner.new(text: "a")),
        inners: [SpecTest::Outer::Middle::Inner.new(text: "b")],
        child: SpecTest::Outer.new(kind: SpecTest::Outer::Kind::KIND_A))
      copy = original.clone
      copy.should eq(original)
      copy.should_not be(original)
      copy.middle.not_nil!.inner.not_nil!.text = "changed"
      copy.inners << SpecTest::Outer::Middle::Inner.new
      copy.child.not_nil!.kind = SpecTest::Outer::Kind::KIND_UNSPECIFIED
      original.middle.not_nil!.inner.not_nil!.text.should eq("a")
      original.inners.size.should eq(1)
      original.child.not_nil!.kind.should eq(SpecTest::Outer::Kind::KIND_A)
    end

    it "clones bytes fields" do
      original = SpecTest::Scalars.new(bytes_value: bytes(1, 2))
      copy = original.clone
      copy.bytes_value[0] = 9_u8
      original.bytes_value.should eq(bytes(1, 2))
    end
  end

  describe "type overrides" do
    it "encodes with the requested wire representation" do
      message = SpecTypeOverrides.new(s32: -1, s64: -2_i64, f32: 3_u32, f64: 4_u64, sf32: -5, sf64: -6_i64)
      message.to_protobuf.should eq(hexbytes(
        "0801 1003 1d03000000 210400000000000000 2dfbffffff 31faffffffffffffff 5007"))
      SpecTypeOverrides.from_protobuf(message.to_protobuf).s32.should eq(-1)
      SpecTypeOverrides.from_protobuf(message.to_protobuf).sf64.should eq(-6_i64)
    end

    it "handles extremes" do
      message = SpecTypeOverrides.new(s32: Int32::MIN, s64: Int64::MIN, f32: UInt32::MAX, f64: UInt64::MAX,
        sf32: Int32::MIN, sf64: Int64::MIN)
      SpecTypeOverrides.from_protobuf(message.to_protobuf).should eq(message)
    end

    it "applies to repeated and map fields" do
      message = SpecTypeOverrides.new(rs32: [-1, 1], rsf64: [-1_i64], m: {-1 => -1_i64})
      message.to_protobuf.should eq(hexbytes("3a02 0102 41ffffffffffffffff 4a0b 0801 11ffffffffffffffff 5007"))
      SpecTypeOverrides.from_protobuf(message.to_protobuf).should eq(message)
    end

    it "applies to optional fields" do
      SpecTypeOverrides.new(optional_s32: 0, with_default: 0).to_protobuf.should eq(hexbytes("7000"))
      SpecTypeOverrides.new(optional_s32: -1, with_default: 0).to_protobuf.should eq(hexbytes("7001"))
    end

    it "uses the default: option as the initial value" do
      SpecTypeOverrides.new.with_default.should eq(7)
      SpecTypeOverrides.from_protobuf(Bytes.empty).with_default.should eq(7)
    end
  end

  describe "DSL" do
    it "resolves types declared later" do
      message = SpecDeclaredLater.new(later: SpecLater.new(value: 1), laters: [SpecLater.new(value: 2)])
      SpecDeclaredLater.from_protobuf(message.to_protobuf).should eq(message)
    end

    it "supports messages without fields" do
      SpecEmptyMessage.new.to_protobuf.should be_empty
      SpecEmptyMessage.from_protobuf(hexbytes("0801")).unknown_fields.should eq(hexbytes("0801"))
      SpecEmptyMessage.new.should eq(SpecEmptyMessage.new)
    end

    it "supports nested types named like built-in types" do
      message = SpecTest::NameClash.new(flag: true, text: "t", answer: SpecTest::NameClash::Bool::YES,
        wrapped: SpecTest::NameClash::String.new(value: "v"), flags: {"a" => true})
      decoded = SpecTest::NameClash.from_protobuf(message.to_protobuf)
      decoded.should eq(message)
      decoded.flag.should be_a(::Bool)
      decoded.text.should be_a(::String)
      decoded.clone.should eq(message)
      ProtobufTestMessages::Proto3::EnumOnlyProto3.new.should eq(ProtobufTestMessages::Proto3::EnumOnlyProto3.new)
      ProtobufTestMessages::Proto2::EnumOnlyProto2.new.clone.to_protobuf.should be_empty
    end

    it "escapes field names that clash with keywords and reserved methods" do
      message = SpecTest::Keywords.new(end_: 1, class_: "c", hash_: true, def_: 2, to_s_: "s", self_: 3)
      decoded = SpecTest::Keywords.from_protobuf(message.to_protobuf)
      decoded.end_.should eq(1)
      decoded.class_.should eq("c")
      decoded.hash_.should be_true
      decoded.to_s_.should eq("s")
      decoded.should eq(message)
      decoded.hash.should eq(message.hash)
    end
  end
end
