require "./protobuf_helper"

# Golden tests against protoc itself, using the official conformance test
# messages (google/protobuf/test_messages_proto{2,3}.proto).
#
# For each case a text-format message is encoded by `protoc --encode`. The
# spec then checks that Crystal decodes the reference bytes to the expected
# values, that Crystal's encoding of the expected message is byte-identical
# to protoc's (maps have at most one entry so ordering is deterministic),
# and that `protoc --decode` of Crystal's bytes gives the same text as for
# the reference bytes.

alias Proto3 = ProtobufTestMessages::Proto3
alias Proto2 = ProtobufTestMessages::Proto2

PROTO3_FILE = "google/protobuf/test_messages_proto3.proto"
PROTO2_FILE = "google/protobuf/test_messages_proto2.proto"
PROTO3_TYPE = "protobuf_test_messages.proto3.TestAllTypesProto3"
PROTO2_TYPE = "protobuf_test_messages.proto2.TestAllTypesProto2"

private def golden3(text : String, expected : Proto3::TestAllTypesProto3, identical = true) : Proto3::TestAllTypesProto3
  reference = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE, text)
  decoded = Proto3::TestAllTypesProto3.from_protobuf(reference)
  decoded.should eq(expected)
  decoded.unknown_fields.should be_empty
  if identical
    ProtobufSpec.hex(expected.to_protobuf).should eq(ProtobufSpec.hex(reference))
  end
  ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, expected.to_protobuf)
    .should eq(ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, reference))
  ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, decoded.to_protobuf)
    .should eq(ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, reference))
  decoded
end

private def golden2(text : String, expected : Proto2::TestAllTypesProto2, identical = true) : Proto2::TestAllTypesProto2
  reference = ProtobufSpec.protoc_encode(PROTO2_TYPE, PROTO2_FILE, text)
  decoded = Proto2::TestAllTypesProto2.from_protobuf(reference)
  decoded.should eq(expected)
  if identical
    ProtobufSpec.hex(expected.to_protobuf).should eq(ProtobufSpec.hex(reference))
  end
  ProtobufSpec.protoc_decode(PROTO2_TYPE, PROTO2_FILE, decoded.to_protobuf)
    .should eq(ProtobufSpec.protoc_decode(PROTO2_TYPE, PROTO2_FILE, reference))
  decoded
end

# Encodes *text* with protoc, decodes it with Crystal and checks that
# re-encoding gives the same bytes.
private def roundtrip3(text : String) : Proto3::TestAllTypesProto3
  reference = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE, text)
  decoded = Proto3::TestAllTypesProto3.from_protobuf(reference)
  ProtobufSpec.hex(decoded.to_protobuf).should eq(ProtobufSpec.hex(reference))
  decoded
end

describe "protoc golden tests" do
  describe "proto3" do
    it "matches protoc for singular scalar fields at their limits" do
      skip_without_protoc
      text = <<-TEXT
        optional_int32: -2147483648
        optional_int64: -9223372036854775808
        optional_uint32: 4294967295
        optional_uint64: 18446744073709551615
        optional_sint32: -2147483648
        optional_sint64: 9223372036854775807
        optional_fixed32: 4294967295
        optional_fixed64: 18446744073709551615
        optional_sfixed32: -2147483648
        optional_sfixed64: -9223372036854775808
        optional_float: -1.5
        optional_double: 1e308
        optional_bool: true
        optional_string: "h\\303\\251llo \\360\\237\\230\\200"
        optional_bytes: "\\000\\001\\377"
        optional_nested_enum: NEG
        optional_foreign_enum: FOREIGN_BAZ
        optional_aliased_enum: ALIAS_BAZ
        optional_string_piece: "piece"
        optional_cord: "cord"
        TEXT
      golden3(text, Proto3::TestAllTypesProto3.new(
        optional_int32: Int32::MIN,
        optional_int64: Int64::MIN,
        optional_uint32: UInt32::MAX,
        optional_uint64: UInt64::MAX,
        optional_sint32: Int32::MIN,
        optional_sint64: Int64::MAX,
        optional_fixed32: UInt32::MAX,
        optional_fixed64: UInt64::MAX,
        optional_sfixed32: Int32::MIN,
        optional_sfixed64: Int64::MIN,
        optional_float: -1.5_f32,
        optional_double: 1e308,
        optional_bool: true,
        optional_string: "héllo 😀",
        optional_bytes: bytes(0, 1, 255),
        optional_nested_enum: Proto3::TestAllTypesProto3::NestedEnum::NEG,
        optional_foreign_enum: Proto3::ForeignEnum::FOREIGN_BAZ,
        optional_aliased_enum: Proto3::TestAllTypesProto3::AliasedEnum::ALIAS_BAZ,
        optional_string_piece: "piece",
        optional_cord: "cord",
      ))
    end

    it "matches protoc for small positive and negative values" do
      skip_without_protoc
      text = <<-TEXT
        optional_int32: -1
        optional_int64: 1
        optional_uint32: 1
        optional_sint32: -1
        optional_sint64: -1
        optional_sfixed64: -1
        optional_float: inf
        optional_double: -inf
        TEXT
      golden3(text, Proto3::TestAllTypesProto3.new(
        optional_int32: -1, optional_int64: 1_i64, optional_uint32: 1_u32, optional_sint32: -1, optional_sint64: -1_i64,
        optional_sfixed64: -1_i64, optional_float: Float32::INFINITY, optional_double: -Float64::INFINITY,
      ))
    end

    it "does not serialize default values, but does serialize -0.0" do
      skip_without_protoc
      reference = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE, "optional_int32: 0 optional_string: \"\" optional_double: -0.0 optional_float: -0.0")
      message = Proto3::TestAllTypesProto3.from_protobuf(reference)
      message.optional_double.sign_bit.should eq(-1)
      message.optional_float.sign_bit.should eq(-1)
      ProtobufSpec.hex(message.to_protobuf).should eq(ProtobufSpec.hex(reference))
      ProtobufSpec.hex(Proto3::TestAllTypesProto3.new(optional_double: -0.0, optional_float: -0.0_f32).to_protobuf)
        .should eq(ProtobufSpec.hex(reference))
    end

    it "preserves NaN" do
      skip_without_protoc
      decoded = roundtrip3("optional_float: nan optional_double: nan repeated_double: [nan, 1]")
      decoded.optional_float.nan?.should be_true
      decoded.optional_double.nan?.should be_true
      decoded.repeated_double[0].nan?.should be_true
    end

    it "matches protoc for nested and recursive messages" do
      skip_without_protoc
      text = <<-TEXT
        optional_nested_message { a: 17 corecursive { optional_int32: 5 } }
        optional_foreign_message { c: -1 }
        recursive_message {
          optional_string: "nested"
          recursive_message { optional_bool: true }
          optional_nested_message {}
        }
        fieldname1: 1
        fieldName7: 7
        FIELD_NAME11: 11
        Field_name18__: 18
        TEXT
      golden3(text, Proto3::TestAllTypesProto3.new(
        optional_nested_message: Proto3::TestAllTypesProto3::NestedMessage.new(
          a: 17, corecursive: Proto3::TestAllTypesProto3.new(optional_int32: 5)),
        optional_foreign_message: Proto3::ForeignMessage.new(c: -1),
        recursive_message: Proto3::TestAllTypesProto3.new(
          optional_string: "nested",
          recursive_message: Proto3::TestAllTypesProto3.new(optional_bool: true),
          optional_nested_message: Proto3::TestAllTypesProto3::NestedMessage.new),
        fieldname1: 1, field_name7: 7, field_name11: 11, field_name18__: 18,
      ))
    end

    it "matches protoc for repeated fields (packed and unpacked)" do
      skip_without_protoc
      text = <<-TEXT
        repeated_int32: [1, -1, 2147483647]
        repeated_int64: [-9223372036854775808, 0]
        repeated_uint32: [0, 4294967295]
        repeated_uint64: [18446744073709551615]
        repeated_sint32: [-1, 1, -2147483648]
        repeated_sint64: [-9223372036854775808, 9223372036854775807]
        repeated_fixed32: [1, 2]
        repeated_fixed64: [3]
        repeated_sfixed32: [-4]
        repeated_sfixed64: [-5]
        repeated_float: [1.5, -0.0]
        repeated_double: [2.5, inf]
        repeated_bool: [true, false, true]
        repeated_string: ["a", "", "\\303\\274"]
        repeated_bytes: ["\\001", ""]
        repeated_nested_message: [{ a: 1 }, {}]
        repeated_foreign_message { c: 2 }
        repeated_nested_enum: [BAR, NEG]
        repeated_foreign_enum: FOREIGN_FOO
        repeated_string_piece: "p"
        repeated_cord: "c"
        packed_int32: [-1, 2]
        packed_sint64: -3
        packed_double: 1
        packed_bool: false
        packed_nested_enum: BAZ
        unpacked_int32: [-1, 2]
        unpacked_int64: 3
        unpacked_uint32: 4
        unpacked_uint64: 5
        unpacked_sint32: -6
        unpacked_sint64: -7
        unpacked_fixed32: 8
        unpacked_fixed64: 9
        unpacked_sfixed32: -10
        unpacked_sfixed64: -11
        unpacked_float: 12.5
        unpacked_double: 13.5
        unpacked_bool: [true, false]
        unpacked_nested_enum: [NEG, FOO]
        TEXT
      golden3(text, Proto3::TestAllTypesProto3.new(
        repeated_int32: [1, -1, Int32::MAX],
        repeated_int64: [Int64::MIN, 0_i64],
        repeated_uint32: [0_u32, UInt32::MAX],
        repeated_uint64: [UInt64::MAX],
        repeated_sint32: [-1, 1, Int32::MIN],
        repeated_sint64: [Int64::MIN, Int64::MAX],
        repeated_fixed32: [1_u32, 2_u32],
        repeated_fixed64: [3_u64],
        repeated_sfixed32: [-4],
        repeated_sfixed64: [-5_i64],
        repeated_float: [1.5_f32, -0.0_f32],
        repeated_double: [2.5, Float64::INFINITY],
        repeated_bool: [true, false, true],
        repeated_string: ["a", "", "ü"],
        repeated_bytes: [bytes(1), Bytes.empty],
        repeated_nested_message: [Proto3::TestAllTypesProto3::NestedMessage.new(a: 1), Proto3::TestAllTypesProto3::NestedMessage.new],
        repeated_foreign_message: [Proto3::ForeignMessage.new(c: 2)],
        repeated_nested_enum: [Proto3::TestAllTypesProto3::NestedEnum::BAR, Proto3::TestAllTypesProto3::NestedEnum::NEG],
        repeated_foreign_enum: [Proto3::ForeignEnum::FOREIGN_FOO],
        repeated_string_piece: ["p"],
        repeated_cord: ["c"],
        packed_int32: [-1, 2],
        packed_sint64: [-3_i64],
        packed_double: [1.0],
        packed_bool: [false],
        packed_nested_enum: [Proto3::TestAllTypesProto3::NestedEnum::BAZ],
        unpacked_int32: [-1, 2],
        unpacked_int64: [3_i64],
        unpacked_uint32: [4_u32],
        unpacked_uint64: [5_u64],
        unpacked_sint32: [-6],
        unpacked_sint64: [-7_i64],
        unpacked_fixed32: [8_u32],
        unpacked_fixed64: [9_u64],
        unpacked_sfixed32: [-10],
        unpacked_sfixed64: [-11_i64],
        unpacked_float: [12.5_f32],
        unpacked_double: [13.5],
        unpacked_bool: [true, false],
        unpacked_nested_enum: [Proto3::TestAllTypesProto3::NestedEnum::NEG, Proto3::TestAllTypesProto3::NestedEnum::FOO],
      ))
    end

    it "matches protoc for single-entry maps of every kind" do
      skip_without_protoc
      text = <<-TEXT
        map_int32_int32 { key: -1 value: -2 }
        map_int64_int64 { key: -9223372036854775808 value: 9223372036854775807 }
        map_uint32_uint32 { key: 4294967295 value: 0 }
        map_uint64_uint64 { key: 0 value: 18446744073709551615 }
        map_sint32_sint32 { key: -2147483648 value: 2147483647 }
        map_sint64_sint64 { key: -1 value: 1 }
        map_fixed32_fixed32 { key: 1 value: 2 }
        map_fixed64_fixed64 { key: 3 value: 4 }
        map_sfixed32_sfixed32 { key: -5 value: -6 }
        map_sfixed64_sfixed64 { key: -7 value: -8 }
        map_int32_float { key: 1 value: -0.0 }
        map_int32_double { key: 2 value: 2.5 }
        map_bool_bool { key: true value: true }
        map_string_string { key: "\\320\\272\\320\\273\\321\\216\\321\\207" value: "\\320\\267\\320\\275\\320\\260\\321\\207\\320\\265\\320\\275\\320\\270\\320\\265" }
        map_string_bytes { key: "" value: "\\000" }
        map_string_nested_message { key: "m" value { a: 5 } }
        map_string_foreign_message { key: "f" value {} }
        map_string_nested_enum { key: "e" value: NEG }
        map_string_foreign_enum { key: "g" value: FOREIGN_FOO }
        TEXT
      golden3(text, Proto3::TestAllTypesProto3.new(
        map_int32_int32: {-1 => -2},
        map_int64_int64: {Int64::MIN => Int64::MAX},
        map_uint32_uint32: {UInt32::MAX => 0_u32},
        map_uint64_uint64: {0_u64 => UInt64::MAX},
        map_sint32_sint32: {Int32::MIN => Int32::MAX},
        map_sint64_sint64: {-1_i64 => 1_i64},
        map_fixed32_fixed32: {1_u32 => 2_u32},
        map_fixed64_fixed64: {3_u64 => 4_u64},
        map_sfixed32_sfixed32: {-5 => -6},
        map_sfixed64_sfixed64: {-7_i64 => -8_i64},
        map_int32_float: {1 => -0.0_f32},
        map_int32_double: {2 => 2.5},
        map_bool_bool: {true => true},
        map_string_string: {"ключ" => "значение"},
        map_string_bytes: {"" => bytes(0)},
        map_string_nested_message: {"m" => Proto3::TestAllTypesProto3::NestedMessage.new(a: 5)},
        map_string_foreign_message: {"f" => Proto3::ForeignMessage.new},
        map_string_nested_enum: {"e" => Proto3::TestAllTypesProto3::NestedEnum::NEG},
        map_string_foreign_enum: {"g" => Proto3::ForeignEnum::FOREIGN_FOO},
      ))
    end

    it "decodes multi-entry maps and matches protoc's text output" do
      skip_without_protoc
      text = <<-TEXT
        map_int32_int32 [{ key: 3 value: 30 }, { key: 1 value: 10 }, { key: 2 value: 20 }]
        map_string_string [{ key: "b" value: "2" }, { key: "a" value: "1" }]
        map_bool_bool [{ key: true value: false }, { key: false value: true }]
        map_string_nested_message [{ key: "x" value { a: 1 } }, { key: "y" value {} }]
        TEXT
      reference = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE, text)
      decoded = Proto3::TestAllTypesProto3.from_protobuf(reference)
      decoded.map_int32_int32.should eq({1 => 10, 2 => 20, 3 => 30})
      decoded.map_string_string.should eq({"a" => "1", "b" => "2"})
      decoded.map_bool_bool.should eq({true => false, false => true})
      decoded.map_string_nested_message["x"].a.should eq(1)
      ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, decoded.to_protobuf)
        .should eq(ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, reference))
    end

    it "matches protoc for duplicate map keys (last wins)" do
      skip_without_protoc
      reference = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE,
        "map_int32_int32 { key: 1 value: 1 } map_int32_int32 { key: 1 value: 2 }")
      decoded = Proto3::TestAllTypesProto3.from_protobuf(reference)
      decoded.map_int32_int32.should eq({1 => 2})
      ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, decoded.to_protobuf).should eq("map_int32_int32 {\n  key: 1\n  value: 2\n}\n")
    end

    {
      "oneof_uint32: 0"                    => Proto3::TestAllTypesProto3.new(oneof_uint32: 0_u32),
      "oneof_uint32: 4294967295"           => Proto3::TestAllTypesProto3.new(oneof_uint32: UInt32::MAX),
      "oneof_nested_message { a: 1 }"      => Proto3::TestAllTypesProto3.new(oneof_nested_message: Proto3::TestAllTypesProto3::NestedMessage.new(a: 1)),
      "oneof_nested_message {}"            => Proto3::TestAllTypesProto3.new(oneof_nested_message: Proto3::TestAllTypesProto3::NestedMessage.new),
      "oneof_string: \"\""                 => Proto3::TestAllTypesProto3.new(oneof_string: ""),
      "oneof_string: \"x\""                => Proto3::TestAllTypesProto3.new(oneof_string: "x"),
      "oneof_bytes: \"\\001\""             => Proto3::TestAllTypesProto3.new(oneof_bytes: bytes(1)),
      "oneof_bool: false"                  => Proto3::TestAllTypesProto3.new(oneof_bool: false),
      "oneof_uint64: 18446744073709551615" => Proto3::TestAllTypesProto3.new(oneof_uint64: UInt64::MAX),
      "oneof_float: 0"                     => Proto3::TestAllTypesProto3.new(oneof_float: 0.0_f32),
      "oneof_double: -2.5"                 => Proto3::TestAllTypesProto3.new(oneof_double: -2.5),
      "oneof_enum: NEG"                    => Proto3::TestAllTypesProto3.new(oneof_enum: Proto3::TestAllTypesProto3::NestedEnum::NEG),
      "oneof_null_value: NULL_VALUE"       => Proto3::TestAllTypesProto3.new(oneof_null_value: Google::Protobuf::NullValue::NULL_VALUE),
    }.each do |text, expected|
      it "matches protoc for oneof #{text}" do
        skip_without_protoc
        decoded = golden3(text, expected)
        decoded.oneof_field_case.should eq(expected.oneof_field_case)
      end
    end

    it "keeps the last oneof member on the wire, like protoc" do
      skip_without_protoc
      reference = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE, "oneof_uint32: 1") +
                  ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE, "oneof_string: \"s\"")
      decoded = Proto3::TestAllTypesProto3.from_protobuf(reference)
      decoded.oneof_field_case.should eq(:oneof_string)
      decoded.oneof_uint32.should be_nil
      ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, decoded.to_protobuf).should eq("oneof_string: \"s\"\n")
      ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, reference).should eq("oneof_string: \"s\"\n")
    end

    it "merges like protoc when messages are concatenated" do
      skip_without_protoc
      a = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE,
        "optional_int32: 1 optional_nested_message { a: 1 } repeated_int32: [1] map_int32_int32 { key: 1 value: 1 } optional_timestamp { seconds: 5 }")
      b = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE,
        "optional_int32: 2 optional_nested_message { corecursive { optional_int32: 3 } } repeated_int32: [2] map_int32_int32 { key: 1 value: 9 } optional_timestamp { nanos: 6 }")
      decoded = Proto3::TestAllTypesProto3.from_protobuf(a + b)
      decoded.optional_int32.should eq(2)
      decoded.optional_nested_message.not_nil!.a.should eq(1)
      decoded.optional_nested_message.not_nil!.corecursive.not_nil!.optional_int32.should eq(3)
      decoded.repeated_int32.should eq([1, 2])
      decoded.map_int32_int32.should eq({1 => 9})
      decoded.optional_timestamp.should eq(Google::Protobuf::Timestamp.new(seconds: 5_i64, nanos: 6))
      merged = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE,
        "optional_int32: 2 optional_nested_message { a: 1 corecursive { optional_int32: 3 } } repeated_int32: [1, 2] map_int32_int32 { key: 1 value: 9 } optional_timestamp { seconds: 5 nanos: 6 }")
      ProtobufSpec.hex(decoded.to_protobuf).should eq(ProtobufSpec.hex(merged))
    end

    it "matches protoc for well-known types" do
      skip_without_protoc
      text = <<-TEXT
        optional_bool_wrapper { value: true }
        optional_int32_wrapper { value: -1 }
        optional_int64_wrapper {}
        optional_uint32_wrapper { value: 1 }
        optional_uint64_wrapper { value: 2 }
        optional_float_wrapper { value: 1.5 }
        optional_double_wrapper { value: -0.0 }
        optional_string_wrapper { value: "s" }
        optional_bytes_wrapper { value: "\\t" }
        repeated_int32_wrapper [{ value: 1 }, {}]
        optional_duration { seconds: -1 nanos: -500 }
        optional_timestamp { seconds: 1700000000 nanos: 1 }
        optional_field_mask { paths: ["a.b", "c"] }
        optional_struct {
          fields {
            key: "k"
            value { list_value { values [{ null_value: NULL_VALUE }, { bool_value: true }, { struct_value {} }] } }
          }
        }
        optional_any { [type.googleapis.com/protobuf_test_messages.proto3.ForeignMessage] { c: 7 } }
        optional_value { number_value: 1.25 }
        optional_null_value: NULL_VALUE
        optional_empty {}
        repeated_duration { seconds: 1 }
        repeated_timestamp {}
        repeated_fieldmask { paths: "x" }
        repeated_struct {}
        repeated_any { type_url: "t" }
        repeated_value { string_value: "v" }
        repeated_list_value {}
        repeated_empty [{}, {}]
        TEXT
      golden3(text, Proto3::TestAllTypesProto3.new(
        optional_bool_wrapper: Google::Protobuf::BoolValue.new(value: true),
        optional_int32_wrapper: Google::Protobuf::Int32Value.new(value: -1),
        optional_int64_wrapper: Google::Protobuf::Int64Value.new,
        optional_uint32_wrapper: Google::Protobuf::UInt32Value.new(value: 1_u32),
        optional_uint64_wrapper: Google::Protobuf::UInt64Value.new(value: 2_u64),
        optional_float_wrapper: Google::Protobuf::FloatValue.new(value: 1.5_f32),
        optional_double_wrapper: Google::Protobuf::DoubleValue.new(value: -0.0),
        optional_string_wrapper: Google::Protobuf::StringValue.new(value: "s"),
        optional_bytes_wrapper: Google::Protobuf::BytesValue.new(value: bytes(9)),
        repeated_int32_wrapper: [Google::Protobuf::Int32Value.new(value: 1), Google::Protobuf::Int32Value.new],
        optional_duration: Google::Protobuf::Duration.new(seconds: -1_i64, nanos: -500),
        optional_timestamp: Google::Protobuf::Timestamp.new(seconds: 1_700_000_000_i64, nanos: 1),
        optional_field_mask: Google::Protobuf::FieldMask.new(paths: ["a.b", "c"]),
        optional_struct: Google::Protobuf::Struct.new(fields: {"k" => Google::Protobuf::Value.new(
          list_value: Google::Protobuf::ListValue.new(values: [
            Google::Protobuf::Value.new(null_value: Google::Protobuf::NullValue::NULL_VALUE),
            Google::Protobuf::Value.new(bool_value: true),
            Google::Protobuf::Value.new(struct_value: Google::Protobuf::Struct.new),
          ]))}),
        optional_any: Google::Protobuf::Any.new(type_url: "type.googleapis.com/protobuf_test_messages.proto3.ForeignMessage", value: bytes(0x08, 0x07)),
        optional_value: Google::Protobuf::Value.new(number_value: 1.25),
        optional_null_value: Google::Protobuf::NullValue::NULL_VALUE,
        optional_empty: Google::Protobuf::Empty.new,
        repeated_duration: [Google::Protobuf::Duration.new(seconds: 1_i64)],
        repeated_timestamp: [Google::Protobuf::Timestamp.new],
        repeated_fieldmask: [Google::Protobuf::FieldMask.new(paths: ["x"])],
        repeated_struct: [Google::Protobuf::Struct.new],
        repeated_any: [Google::Protobuf::Any.new(type_url: "t")],
        repeated_value: [Google::Protobuf::Value.new(string_value: "v")],
        repeated_list_value: [Google::Protobuf::ListValue.new],
        repeated_empty: [Google::Protobuf::Empty.new, Google::Protobuf::Empty.new],
      ))
    end

    it "decodes into the embedded Any payload" do
      skip_without_protoc
      decoded = roundtrip3("optional_any { [type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3] { optional_int32: 3 map_string_string { key: \"a\" value: \"b\" } } }")
      any = decoded.optional_any.not_nil!
      any.type_url.should eq("type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3")
      inner = Proto3::TestAllTypesProto3.from_protobuf(any.value)
      inner.optional_int32.should eq(3)
      inner.map_string_string.should eq({"a" => "b"})
    end

    it "preserves unknown enum values" do
      skip_without_protoc
      # Encode as TestAllTypesProto3 with an out-of-range enum via a raw varint.
      reference = hexbytes("a801 e707") # optional_nested_enum (21) = 999
      decoded = Proto3::TestAllTypesProto3.from_protobuf(reference)
      decoded.optional_nested_enum.value.should eq(999)
      decoded.to_protobuf.should eq(reference)
      ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, decoded.to_protobuf).should eq("optional_nested_enum: 999\n")
    end

    it "preserves unknown fields so protoc can read them back" do
      skip_without_protoc
      reference = ProtobufSpec.protoc_encode(PROTO3_TYPE, PROTO3_FILE,
        "optional_int32: 1 optional_string: \"x\" repeated_double: [1, 2] optional_nested_message { a: 1 } optional_timestamp { seconds: 3 } map_string_string { key: \"k\" value: \"v\" }")
      empty = Proto3::NullHypothesisProto3.from_protobuf(reference)
      empty.unknown_fields.should eq(reference)
      empty.to_protobuf.should eq(reference)
      ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, empty.to_protobuf)
        .should eq(ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, reference))

      # Unknown fields of a different message are kept and printed by number.
      foreign = Proto3::ForeignMessage.from_protobuf(reference)
      foreign.c.should eq(1)
      ProtobufSpec.protoc_decode("protobuf_test_messages.proto3.ForeignMessage", PROTO3_FILE, foreign.to_protobuf)
        .should contain("14: \"x\"")
    end

    it "is readable by protoc --decode" do
      skip_without_protoc
      message = Proto3::TestAllTypesProto3.new(
        optional_int32: -7, optional_string: "ok", repeated_sint32: [-1, 2],
        oneof_enum: Proto3::TestAllTypesProto3::NestedEnum::BAR,
        map_string_foreign_enum: {"z" => Proto3::ForeignEnum::FOREIGN_BAR})
      ProtobufSpec.protoc_decode(PROTO3_TYPE, PROTO3_FILE, message.to_protobuf).should eq(<<-TEXT)
        optional_int32: -7
        optional_string: "ok"
        repeated_sint32: -1
        repeated_sint32: 2
        map_string_foreign_enum {
          key: "z"
          value: FOREIGN_BAR
        }
        oneof_enum: BAR

        TEXT
    end
  end

  describe "proto2" do
    it "matches protoc for explicit presence, defaults and unpacked repeated fields" do
      skip_without_protoc
      text = <<-TEXT
        optional_int32: 0
        optional_int64: -1
        optional_uint32: 0
        optional_sint32: -2
        optional_fixed64: 0
        optional_float: 0
        optional_double: -0.0
        optional_bool: false
        optional_string: ""
        optional_bytes: ""
        optional_nested_message { a: 0 }
        optional_nested_enum: FOO
        optional_foreign_enum: FOREIGN_BAR
        repeated_int32: [1, -1]
        repeated_string: "a"
        repeated_nested_enum: NEG
        packed_int32: [1, -1]
        packed_double: 0.5
        unpacked_sint64: -1
        map_int32_int32 { key: 0 value: 0 }
        oneof_uint32: 0
        default_int32: 0
        default_string: ""
        default_bool: false
        TEXT
      golden2(text, Proto2::TestAllTypesProto2.new(
        optional_int32: 0,
        optional_int64: -1_i64,
        optional_uint32: 0_u32,
        optional_sint32: -2,
        optional_fixed64: 0_u64,
        optional_float: 0.0_f32,
        optional_double: -0.0,
        optional_bool: false,
        optional_string: "",
        optional_bytes: Bytes.empty,
        optional_nested_message: Proto2::TestAllTypesProto2::NestedMessage.new(a: 0),
        optional_nested_enum: Proto2::TestAllTypesProto2::NestedEnum::FOO,
        optional_foreign_enum: Proto2::ForeignEnumProto2::FOREIGN_BAR,
        repeated_int32: [1, -1],
        repeated_string: ["a"],
        repeated_nested_enum: [Proto2::TestAllTypesProto2::NestedEnum::NEG],
        packed_int32: [1, -1],
        packed_double: [0.5],
        unpacked_sint64: [-1_i64],
        map_int32_int32: {0 => 0},
        oneof_uint32: 0_u32,
        default_int32: 0,
        default_string: "",
        default_bool: false,
      ))
    end

    it "keeps unset fields nil and applies proto2 defaults through _or_default" do
      message = Proto2::TestAllTypesProto2.new
      message.default_int32.should be_nil
      message.default_string.should be_nil
      message.default_int32_or_default.should eq(-123456789)
      message.default_string_or_default.should eq("Rosebud")
      message.to_protobuf.should be_empty
    end

    it "decodes groups as fields and round trips them byte for byte" do
      skip_without_protoc
      text = <<-TEXT
        optional_int32: 1
        repeated_int32: [2, 3]
        data { group_int32: 5 group_uint32: 6 }
        multiwordgroupfield { group_int32: -1 }
        TEXT
      reference = ProtobufSpec.protoc_encode(PROTO2_TYPE, PROTO2_FILE, text)
      decoded = Proto2::TestAllTypesProto2.from_protobuf(reference)
      decoded.optional_int32.should eq(1)
      decoded.repeated_int32.should eq([2, 3])
      decoded.data.should eq(Proto2::TestAllTypesProto2::Data.new(group_int32: 5, group_uint32: 6))
      decoded.multiwordgroupfield.should eq(Proto2::TestAllTypesProto2::MultiWordGroupField.new(group_int32: -1))
      decoded.unknown_fields.should be_empty
      ProtobufSpec.hex(decoded.to_protobuf).should eq(ProtobufSpec.hex(reference))
      ProtobufSpec.protoc_decode(PROTO2_TYPE, PROTO2_FILE, decoded.to_protobuf)
        .should eq(ProtobufSpec.protoc_decode(PROTO2_TYPE, PROTO2_FILE, reference))
    end

    it "keeps group data when fields with higher numbers are present" do
      skip_without_protoc
      text = "data { group_int32: 5 } default_int32: 7 fieldname1: 1"
      reference = ProtobufSpec.protoc_encode(PROTO2_TYPE, PROTO2_FILE, text)
      decoded = Proto2::TestAllTypesProto2.from_protobuf(reference)
      decoded.default_int32.should eq(7)
      decoded.fieldname1.should eq(1)
      decoded.data.not_nil!.group_int32.should eq(5)
      ProtobufSpec.hex(decoded.to_protobuf).should eq(ProtobufSpec.hex(reference))
      ProtobufSpec.protoc_decode(PROTO2_TYPE, PROTO2_FILE, decoded.to_protobuf)
        .should eq(ProtobufSpec.protoc_decode(PROTO2_TYPE, PROTO2_FILE, reference))
    end

    it "round trips groups nested in unknown messages" do
      skip_without_protoc
      reference = ProtobufSpec.protoc_encode(PROTO2_TYPE, PROTO2_FILE,
        "recursive_message { data { group_int32: 1 } recursive_message { multiwordgroupfield { group_uint32: 2 } } }")
      decoded = Proto2::TestAllTypesProto2.from_protobuf(reference)
      ProtobufSpec.hex(decoded.to_protobuf).should eq(ProtobufSpec.hex(reference))
    end

    it "parses registered extensions" do
      skip_without_protoc
      reference = ProtobufSpec.protoc_encode(PROTO2_TYPE, PROTO2_FILE,
        "[protobuf_test_messages.proto2.extension_int32]: 5 [protobuf_test_messages.proto2.groupfield] { group_int32: 1 }")
      decoded = Proto2::TestAllTypesProto2.from_protobuf(reference)
      decoded.unknown_fields.should be_empty
      decoded.get_extension(Proto2::EXTENSION_INT32).should eq(5)
      decoded.get_extension(Proto2::GROUPFIELD).should eq(Proto2::GroupField.new(group_int32: 1))
      decoded.to_protobuf.should eq(reference)
      ProtobufSpec.protoc_decode(PROTO2_TYPE, PROTO2_FILE, decoded.to_protobuf)
        .should eq(ProtobufSpec.protoc_decode(PROTO2_TYPE, PROTO2_FILE, reference))
    end

    it "does not validate UTF-8 in proto2 strings" do
      skip_without_protoc
      reference = hexbytes("7202 c328") # optional_string = "\xc3\x28"
      decoded = Proto2::TestAllTypesProto2.from_protobuf(reference)
      decoded.optional_string.not_nil!.to_slice.should eq(bytes(0xc3, 0x28))
      decoded.to_protobuf.should eq(reference)
      expect_raises(Protobuf::DecodeError) { Proto3::TestAllTypesProto3.from_protobuf(reference) }
    end

    it "serializes required fields set to default values" do
      message = Proto2::TestAllRequiredTypesProto2.new(required_int32: 0, required_string: "")
      message.to_protobuf.should eq(hexbytes("0800 7200"))
    end
  end
end
