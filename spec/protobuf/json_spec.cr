require "./protobuf_helper"

private alias P3 = ProtobufTestMessages::Proto3::TestAllTypesProto3
private alias P2 = ProtobufTestMessages::Proto2::TestAllTypesProto2
private alias GP = Google::Protobuf

private def json(message : Protobuf::Message, **options) : JSON::Any
  JSON.parse(message.to_json(**options))
end

private def parse(text : String, ignore_unknown_fields = false) : P3
  P3.from_json(text, ignore_unknown_fields: ignore_unknown_fields)
end

private def parse_error(text : String, message : String | Regex? = nil, file = __FILE__, line = __LINE__)
  error = expect_raises(Protobuf::JSON::ParseError, file: file, line: line) { P3.from_json(text) }
  case message
  in String then error.message.not_nil!.should contain(message), file: file, line: line
  in Regex  then error.message.not_nil!.should match(message), file: file, line: line
  in Nil
  end
end

# Prints *message*, parses it back and checks it is unchanged.
private def round_trip(message : T, file = __FILE__, line = __LINE__) forall T
  [message.to_json, message.to_json(emit_defaults: true, preserve_proto_field_names: true, enums_as_ints: true)].each do |text|
    message_should_eq(T.from_json(text), message, file, line)
  end
end

describe "Protobuf JSON mapping" do
  describe "printing" do
    it "omits default values of fields without presence" do
      P3.new.to_json.should eq("{}")
      P3.new(optional_int32: 0, optional_string: "").to_json.should eq("{}")
    end

    it "uses lowerCamelCase names, or proto names on request" do
      message = P3.new(optional_int32: 1, field_name2: 2, field__name4_: 4, field_name7: 7, field_name12: 12, field_name18__: 18)
      json(message).as_h.keys.should eq(%w(optionalInt32 fieldName2 fieldName4 fieldName7 FIELDName12 FieldName18))
      json(message, preserve_proto_field_names: true).as_h.keys.should eq(%w(optional_int32 field_name2 field__name4_ fieldName7 FIELD_name12 Field_name18__))
    end

    it "prints 64-bit integers as strings and 32-bit integers as numbers" do
      message = P3.new(optional_int32: -1, optional_uint32: UInt32::MAX, optional_int64: Int64::MIN, optional_uint64: UInt64::MAX,
        optional_sint64: -2_i64, optional_fixed64: 3_u64, optional_sfixed64: -4_i64)
      message.to_json.should eq(%({"optionalInt32":-1,"optionalInt64":"-9223372036854775808","optionalUint32":4294967295,) +
                                %("optionalUint64":"18446744073709551615","optionalSint64":"-2","optionalFixed64":"3","optionalSfixed64":"-4"}))
    end

    it "prints floats, including special values" do
      P3.new(optional_float: 1.1_f32, optional_double: -2.5).to_json.should eq(%({"optionalFloat":1.1,"optionalDouble":-2.5}))
      P3.new(optional_double: Float64::NAN).to_json.should eq(%({"optionalDouble":"NaN"}))
      P3.new(optional_double: Float64::INFINITY, optional_float: -Float32::INFINITY).to_json
        .should eq(%({"optionalFloat":"-Infinity","optionalDouble":"Infinity"}))
      P3.new(optional_double: -0.0).to_json.should eq(%({"optionalDouble":-0.0}))
      P3.new(optional_double: 1e300).to_json.should eq(%({"optionalDouble":1.0e+300}))
    end

    it "prints bytes as standard base64 with padding" do
      P3.new(optional_bytes: Bytes[0xfb, 0xff, 0x01]).to_json.should eq(%({"optionalBytes":"+/8B"}))
      P3.new(optional_bytes: Bytes[1]).to_json.should eq(%({"optionalBytes":"AQ=="}))
    end

    it "prints enums by name, unknown values as numbers, or numbers on request" do
      P3.new(optional_nested_enum: P3::NestedEnum::BAZ).to_json.should eq(%({"optionalNestedEnum":"BAZ"}))
      P3.new(optional_nested_enum: P3::NestedEnum.new(42)).to_json.should eq(%({"optionalNestedEnum":42}))
      P3.new(optional_nested_enum: P3::NestedEnum::NEG).to_json(enums_as_ints: true).should eq(%({"optionalNestedEnum":-1}))
      # Aliased values print the first name.
      P3.new(optional_aliased_enum: P3::AliasedEnum::ALIAS_BAZ).to_json.should eq(%({"optionalAliasedEnum":"ALIAS_BAZ"}))
    end

    it "prints repeated fields, maps and oneofs" do
      message = P3.new(repeated_int64: [1_i64, -2_i64], map_bool_bool: {true => false}, map_int32_int32: {-1 => 1},
        map_uint64_uint64: {UInt64::MAX => 1_u64}, map_string_nested_message: {"k" => P3::NestedMessage.new(a: 1)},
        oneof_uint32: 0_u32)
      json(message).should eq(JSON.parse(%({"repeatedInt64":["1","-2"],"mapInt32Int32":{"-1":1},"mapUint64Uint64":{"18446744073709551615":"1"},) +
                                         %("mapBoolBool":{"true":false},"mapStringNestedMessage":{"k":{"a":1}},"oneofUint32":0})))
    end

    it "prints fields without presence with emit_defaults" do
      printed = json(P3.new, emit_defaults: true).as_h
      printed["optionalInt32"].should eq(0)
      printed["optionalInt64"].should eq("0")
      printed["optionalString"].should eq("")
      printed["optionalBytes"].should eq("")
      printed["optionalNestedEnum"].should eq("FOO")
      printed["repeatedInt32"].should eq([] of JSON::Any)
      printed["mapStringString"].as_h.should be_empty
      # Message fields and oneofs have presence and are not printed.
      printed.has_key?("optionalNestedMessage").should be_false
      printed.has_key?("oneofUint32").should be_false
      # proto2 optional fields have presence too.
      JSON.parse(P2.new.to_json(emit_defaults: true)).as_h.has_key?("optionalInt32").should be_false
    end

    it "pretty prints with an indent" do
      P3.new(optional_int32: 1).to_json(indent: "  ").should eq("{\n  \"optionalInt32\": 1\n}")
    end

    it "integrates with the standard library" do
      [P3.new(optional_int32: 1), P3.new].to_json.should eq(%([{"optionalInt32":1},{}]))
      JSON.build { |builder| P3.new(optional_bool: true).to_json(builder) }.should eq(%({"optionalBool":true}))
      Array(P3).from_json(%([{"optionalInt32":2}])).should eq([P3.new(optional_int32: 2)])
      Hash(String, GP::Duration).from_json(%({"a":"1s"})).should eq({"a" => GP::Duration.new(seconds: 1)})
      io = IO::Memory.new
      P3.new(optional_int32: 3).to_json(io)
      io.to_s.should eq(%({"optionalInt32":3}))
    end

    it "uses custom json_name options" do
      message = SpecTest::Proto2::JsonNames.from_json(%({"customName":1}))
      message.renamed.should eq(1)
      message.to_json.should eq(%({"customName":1}))
      message.to_json(preserve_proto_field_names: true).should eq(%({"renamed":1}))
    end
  end

  describe "parsing" do
    it "accepts lowerCamelCase and proto names" do
      parse(%({"optionalInt32":1,"optional_int64":"2","fieldName7":7,"FIELDName12":12,"FIELD_name12x":0}), true)
        .should eq(P3.new(optional_int32: 1, optional_int64: 2_i64, field_name7: 7, field_name12: 12))
      parse(%({"Field_name18__":1})).field_name18__.should eq(1)
    end

    it "accepts integers as numbers or strings, in exponent notation when integral" do
      parse(%({"optionalInt32":"-5","optionalInt64":12,"optionalUint64":"18446744073709551615"}))
        .should eq(P3.new(optional_int32: -5, optional_int64: 12_i64, optional_uint64: UInt64::MAX))
      parse(%({"optionalInt32":1e5,"optionalInt64":"1.0e3","optionalUint32":4.0})).should eq(P3.new(optional_int32: 100000, optional_int64: 1000_i64, optional_uint32: 4_u32))
      parse(%({"optionalInt64":9223372036854775807})).optional_int64.should eq(Int64::MAX)
    end

    it "rejects non-integral, out of range and malformed integers" do
      parse_error(%({"optionalInt32":1.5}), "Invalid integer")
      parse_error(%({"optionalInt32":2147483648}), "out of range")
      parse_error(%({"optionalUint32":-1}), "out of range")
      parse_error(%({"optionalUint64":"18446744073709551616"}), "out of range")
      parse_error(%({"optionalInt64":"9223372036854775808"}), "out of range")
      parse_error(%({"optionalInt32":" 1"}), "Invalid integer")
      parse_error(%({"optionalInt32":"0x10"}), "Invalid integer")
      parse_error(%({"optionalInt32":"01"}), "Invalid integer")
      parse_error(%({"optionalInt32":true}), "Expected an integer")
      parse_error(%({"optionalInt32":1e999999999999}), "Invalid integer")
    end

    it "accepts floats as numbers or strings, including special values" do
      message = parse(%({"optionalFloat":"1.5","optionalDouble":"-Infinity","repeatedDouble":["NaN","Infinity",1e-300, -0]}))
      message.optional_float.should eq(1.5_f32)
      message.optional_double.should eq(-Float64::INFINITY)
      message.repeated_double[0].nan?.should be_true
      message.repeated_double[1..].should eq([Float64::INFINITY, 1e-300, 0.0])
    end

    it "rejects floats out of range" do
      parse_error(%({"optionalDouble":1.89769e+308}), "out of range")
      parse_error(%({"optionalFloat":3.502823e+38}), "out of range")
      parse_error(%({"optionalFloat":"nan"}), "Invalid number")
      parse_error(%({"optionalDouble":"1.5 "}), "Invalid number")
    end

    it "accepts standard and URL-safe base64, with or without padding" do
      %w(+/8B -_8B AQ== AQ AQI= AQI).zip([Bytes[0xfb, 0xff, 1], Bytes[0xfb, 0xff, 1], Bytes[1], Bytes[1], Bytes[1, 2], Bytes[1, 2]]).each do |(text, bytes)|
        parse(%({"optionalBytes":"#{text}"})).optional_bytes.should eq(bytes)
      end
      parse_error(%({"optionalBytes":"A"}), "base64")
      parse_error(%({"optionalBytes":"AQ=x"}), "base64")
      parse_error(%({"optionalBytes":"A!=="}), "base64")
    end

    it "accepts enums by name or number" do
      parse(%({"optionalNestedEnum":"BAR","repeatedNestedEnum":[2,"NEG",123]})).should eq(
        P3.new(optional_nested_enum: P3::NestedEnum::BAR, repeated_nested_enum: [P3::NestedEnum::BAZ, P3::NestedEnum::NEG, P3::NestedEnum.new(123)]))
      parse(%({"optionalAliasedEnum":"moo"})).optional_aliased_enum.should eq(P3::AliasedEnum::ALIAS_BAZ)
    end

    it "rejects unknown enum names unless unknown fields are ignored" do
      parse_error(%({"optionalNestedEnum":"QUX"}), %(Unknown value "QUX"))
      parse(%({"optionalNestedEnum":"QUX","repeatedNestedEnum":["FOO","QUX"],"mapStringNestedEnum":{"a":"QUX","b":"BAR"}}), true)
        .should eq(P3.new(repeated_nested_enum: [P3::NestedEnum::FOO], map_string_nested_enum: {"b" => P3::NestedEnum::BAR}))
    end

    it "rejects unknown values of closed enums" do
      expect_raises(Protobuf::JSON::ParseError, /closed enum/) { P2.from_json(%({"optionalNestedEnum":42})) }
      P2.from_json(%({"optionalNestedEnum":42}), ignore_unknown_fields: true).optional_nested_enum.should be_nil
    end

    it "treats null as an unset field" do
      parse(%({"optionalInt32":null,"optionalNestedMessage":null,"repeatedInt32":null,"mapStringString":null,"oneofUint32":null,"optionalTimestamp":null}))
        .should eq(P3.new)
    end

    it "parses null as a Value and NullValue" do
      message = parse(%({"optionalValue":null,"optionalNullValue":null,"repeatedValue":[null,1]}))
      message.optional_value.should eq(GP::Value.new(null_value: GP::NullValue::NULL_VALUE))
      message.optional_null_value.should eq(GP::NullValue::NULL_VALUE)
      message.repeated_value.size.should eq(2)
      parse(%({"optionalNullValue":"NULL_VALUE"})).optional_null_value.should eq(GP::NullValue::NULL_VALUE)
    end

    it "rejects null in repeated fields and map values" do
      parse_error(%({"repeatedInt32":[1,null]}))
      parse_error(%({"mapStringString":{"a":null}}), "must not be null")
    end

    it "parses map keys" do
      parse(%({"mapInt32Int32":{"-1":2},"mapBoolBool":{"true":true,"false":false},"mapUint64Uint64":{"18446744073709551615":"1"}}))
        .should eq(P3.new(map_int32_int32: {-1 => 2}, map_bool_bool: {true => true, false => false}, map_uint64_uint64: {UInt64::MAX => 1_u64}))
      parse_error(%({"mapBoolBool":{"TRUE":true}}), "Invalid boolean map key")
      parse_error(%({"mapInt32Int32":{"1.5":1}}), "Invalid integer map key")
      parse_error(%({"mapInt32Int32":{"1":1,"1":2}}), "Duplicate map key")
    end

    it "rejects duplicate fields, including through both names" do
      parse_error(%({"optionalInt32":1,"optionalInt32":2}), "Duplicate field")
      parse_error(%({"optionalInt32":1,"optional_int32":2}), "Duplicate field")
    end

    it "rejects several members of a oneof" do
      parse_error(%({"oneofUint32":1,"oneofString":"a"}), "oneof")
      parse(%({"oneofUint32":null,"oneofString":"a"})).oneof_string.should eq("a")
    end

    it "rejects or ignores unknown fields" do
      parse_error(%({"unknown":1}), %(Unknown field "unknown"))
      parse(%({"unknown":{"deep":[1,{"x":null}]},"optionalInt32":1}), true).should eq(P3.new(optional_int32: 1))
    end

    it "rejects values of the wrong type" do
      parse_error(%({"optionalString":1}), "Expected a string")
      parse_error(%({"optionalBool":"true"}), "Expected a boolean")
      parse_error(%({"optionalNestedMessage":1}), "Expected an object")
      parse_error(%({"repeatedInt32":1}), "Expected an array")
      parse_error(%({"mapInt32Int32":[]}), "Expected an object")
      parse_error(%([]), "Expected an object")
    end

    it "rejects malformed JSON and trailing content" do
      parse_error(%({"optionalInt32":1,}))
      parse_error(%({"optionalInt32":1} x))
      parse_error(%({"optionalInt32":1}{}))
      parse_error(%({'optionalInt32':1}))
      parse_error("")
    end

    it "enforces the recursion limit" do
      deep = %({"recursiveMessage":) * 150 + "{}" + "}" * 150
      parse_error(deep, "recursion limit")
      P3.from_json(%({"recursiveMessage":) * 50 + "{}" + "}" * 50).recursive_message.should_not be_nil
    end

    it "merges into an existing message" do
      message = P3.new(optional_int32: 1)
      message.merge_from_json(%({"optionalInt64":"2"}))
      message.should eq(P3.new(optional_int32: 1, optional_int64: 2_i64))
    end

    it "round trips every kind of field" do
      round_trip(P3.new(optional_int32: -1, optional_int64: Int64::MIN, optional_uint32: UInt32::MAX, optional_uint64: UInt64::MAX,
        optional_sint32: -3, optional_sint64: -4_i64, optional_fixed32: 5_u32, optional_fixed64: 6_u64, optional_sfixed32: -7,
        optional_sfixed64: -8_i64, optional_float: 0.1_f32, optional_double: 1e-310, optional_bool: true, optional_string: "é\u0000\"",
        optional_bytes: Bytes[0, 255], optional_nested_message: P3::NestedMessage.new(a: 1), optional_nested_enum: P3::NestedEnum.new(7),
        repeated_float: [Float32::MAX, Float32::MIN_POSITIVE], map_string_bytes: {"" => Bytes.empty}, oneof_string: ""))
    end
  end

  describe "well-known types" do
    it "maps Timestamp to RFC 3339" do
      P3.new(optional_timestamp: GP::Timestamp.new(seconds: 0)).to_json.should eq(%({"optionalTimestamp":"1970-01-01T00:00:00Z"}))
      {
        {1, 0}                      => "1970-01-01T00:00:01Z",
        {1, 10_000_000}             => "1970-01-01T00:00:01.010Z",
        {1, 10_000}                 => "1970-01-01T00:00:01.000010Z",
        {1, 10}                     => "1970-01-01T00:00:01.000000010Z",
        {-62135596800, 0}           => "0001-01-01T00:00:00Z",
        {253402300799, 999_999_999} => "9999-12-31T23:59:59.999999999Z",
      }.each do |(seconds, nanos), text|
        timestamp = GP::Timestamp.new(seconds: seconds.to_i64, nanos: nanos)
        timestamp.to_json.should eq(text.to_json)
        GP::Timestamp.from_json(text.to_json).should eq(timestamp)
      end
    end

    it "parses Timestamp offsets and rejects invalid timestamps" do
      GP::Timestamp.from_json(%("1970-01-01T08:00:00+08:00")).seconds.should eq(0)
      GP::Timestamp.from_json(%("1969-12-31T23:00:00.5-01:00")).should eq(GP::Timestamp.new(seconds: 0, nanos: 500_000_000))
      %w(1970-01-01T00:00:00 1970-01-01t00:00:00Z 1970-01-01T00:00:00z 1970-1-01T00:00:00Z 1970-01-01T00:00:00.1234567890Z
        0000-01-01T00:00:00Z 1970-02-30T00:00:00Z 1970-01-01T24:00:00Z 10000-01-01T00:00:00Z 0001-01-01T00:00:00+01:00).each do |text|
        expect_raises(Protobuf::JSON::ParseError) { GP::Timestamp.from_json(text.to_json) }
      end
      expect_raises(Protobuf::JSON::ParseError) { GP::Timestamp.from_json("0") }
    end

    it "refuses to print out-of-range timestamps" do
      expect_raises(Protobuf::JSON::SerializeError) { GP::Timestamp.new(seconds: 253402300800).to_json }
      expect_raises(Protobuf::JSON::SerializeError) { GP::Timestamp.new(nanos: -1).to_json }
    end

    it "maps Duration to seconds with a suffix" do
      {
        {1_i64, 0}            => "1s",
        {1_i64, 500_000_000}  => "1.500s",
        {-1_i64, -500}        => "-1.000000500s",
        {0_i64, -1}           => "-0.000000001s",
        {315576000000_i64, 0} => "315576000000s",
      }.each do |(seconds, nanos), text|
        duration = GP::Duration.new(seconds: seconds, nanos: nanos)
        duration.to_json.should eq(text.to_json)
        GP::Duration.from_json(text.to_json).should eq(duration)
      end
      GP::Duration.from_json(%("1.5s")).should eq(GP::Duration.new(seconds: 1, nanos: 500_000_000))
      %w(1 1.5 s -s 1.0000000001s 315576000001s +1s 1e3s).each do |text|
        expect_raises(Protobuf::JSON::ParseError) { GP::Duration.from_json(text.to_json) }
      end
      expect_raises(Protobuf::JSON::SerializeError) { GP::Duration.new(seconds: 1, nanos: -1).to_json }
      expect_raises(Protobuf::JSON::SerializeError) { GP::Duration.new(seconds: 315576000001).to_json }
    end

    it "maps FieldMask to comma-separated lowerCamelCase paths" do
      mask = GP::FieldMask.new(paths: ["foo_bar", "a.b_c", "x"])
      mask.to_json.should eq(%("fooBar,a.bC,x"))
      GP::FieldMask.from_json(%("fooBar,a.bC,x")).should eq(mask)
      GP::FieldMask.from_json(%("")).should eq(GP::FieldMask.new)
      expect_raises(Protobuf::JSON::ParseError) { GP::FieldMask.from_json(%("foo_bar")) }
      expect_raises(Protobuf::JSON::SerializeError) { GP::FieldMask.new(paths: ["fooBar"]).to_json }
      expect_raises(Protobuf::JSON::SerializeError) { GP::FieldMask.new(paths: ["foo__bar"]).to_json }
      expect_raises(Protobuf::JSON::SerializeError) { GP::FieldMask.new(paths: ["foo_3"]).to_json }
    end

    it "maps Struct, Value and ListValue to arbitrary JSON" do
      text = %({"a":null,"b":1.5,"c":"s","d":true,"e":{"f":[1.0,"x",[],{}]}})
      value = GP::Struct.from_json(text)
      value.fields["a"].null_value.should eq(GP::NullValue::NULL_VALUE)
      value.fields["b"].number_value.should eq(1.5)
      value.fields["e"].struct_value.not_nil!.fields["f"].list_value.not_nil!.values.size.should eq(4)
      JSON.parse(value.to_json).should eq(JSON.parse(text))
      GP::Value.from_json("null").null_value.should eq(GP::NullValue::NULL_VALUE)
      GP::Value.from_json("12").number_value.should eq(12.0)
      GP::ListValue.from_json("[1,null]").values.size.should eq(2)
      expect_raises(Protobuf::JSON::ParseError) { GP::Struct.from_json("[]") }
      expect_raises(Protobuf::JSON::ParseError) { GP::ListValue.from_json("{}") }
      expect_raises(Protobuf::JSON::SerializeError) { GP::Value.new(number_value: Float64::NAN).to_json }
      expect_raises(Protobuf::JSON::SerializeError) { GP::Value.new.to_json }
    end

    it "maps wrappers to their wrapped value" do
      # null elements are not allowed in repeated fields.
      parse_error(%({"repeatedStringWrapper":["",null]}))
      parse(%({"optionalFloatWrapper":"NaN"})).optional_float_wrapper.not_nil!.value.nan?.should be_true
      message = parse(%({"optionalInt64Wrapper":"5","optionalBoolWrapper":false,"optionalBytesWrapper":"AQ==","optionalUint32Wrapper":0,"repeatedStringWrapper":["","x"]}))
      message.optional_int64_wrapper.should eq(GP::Int64Value.new(value: 5_i64))
      message.optional_bool_wrapper.should eq(GP::BoolValue.new(value: false))
      message.optional_bytes_wrapper.should eq(GP::BytesValue.new(value: Bytes[1]))
      message.optional_uint32_wrapper.should eq(GP::UInt32Value.new)
      message.repeated_string_wrapper.should eq([GP::StringValue.new, GP::StringValue.new(value: "x")])
      JSON.parse(message.to_json).should eq(JSON.parse(%({"optionalBoolWrapper":false,"optionalInt64Wrapper":"5","optionalUint32Wrapper":0,"optionalBytesWrapper":"AQ==","repeatedStringWrapper":["","x"]})))
      parse(%({"optionalStringWrapper":null})).optional_string_wrapper.should be_nil
    end

    it "maps Empty to an empty object" do
      parse(%({"optionalEmpty":{}})).optional_empty.should eq(GP::Empty.new)
      P3.new(optional_empty: GP::Empty.new).to_json.should eq(%({"optionalEmpty":{}}))
    end

    it "maps Any with the registry, inline for messages and with a value for well-known types" do
      inner = P3.new(optional_int32: 5)
      any = GP::Any.pack(inner)
      any.type_url.should eq("type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3")
      JSON.parse(any.to_json).should eq(JSON.parse(%({"@type":"type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3","optionalInt32":5})))
      GP::Any.from_json(any.to_json).unpack(P3).should eq(inner)
      # @type may come after the fields.
      GP::Any.from_json(%({"optionalInt32":5,"@type":"type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3"})).should eq(any)

      duration = GP::Any.pack(GP::Duration.new(seconds: 1))
      duration.to_json.should eq(%({"@type":"type.googleapis.com/google.protobuf.Duration","value":"1s"}))
      GP::Any.from_json(duration.to_json).should eq(duration)

      nested = GP::Any.pack(duration)
      nested.to_json.should eq(%({"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1s"}}))
      GP::Any.from_json(nested.to_json).should eq(nested)

      empty = GP::Any.pack(GP::Empty.new)
      empty.to_json.should eq(%({"@type":"type.googleapis.com/google.protobuf.Empty"}))
      GP::Any.from_json(empty.to_json).should eq(empty)
      GP::Any.from_json("{}").should eq(GP::Any.new)
      GP::Any.new.to_json.should eq("{}")
    end

    it "rejects invalid Any values" do
      expect_raises(Protobuf::JSON::ParseError, /unknown Any type/) { GP::Any.from_json(%({"@type":"type.googleapis.com/no.Such"})) }
      expect_raises(Protobuf::JSON::ParseError, /missing @type/) { GP::Any.from_json(%({"a":1})) }
      expect_raises(Protobuf::JSON::ParseError) { GP::Any.from_json(%({"@type":"google.protobuf.Duration","value":"1s"})) }
      expect_raises(Protobuf::JSON::ParseError) { GP::Any.from_json(%({"@type":"type.googleapis.com/google.protobuf.Duration","value":"1s","x":1})) }
      expect_raises(Protobuf::JSON::SerializeError, /unknown type/) { GP::Any.new(type_url: "type.googleapis.com/no.Such").to_json }
    end

    it "unpacks Any values" do
      any = GP::Any.pack(GP::Timestamp.new(seconds: 3), "example.com/types")
      any.type_url.should eq("example.com/types/google.protobuf.Timestamp")
      any.is?(GP::Timestamp).should be_true
      any.is?(GP::Duration).should be_false
      any.unpack.should eq(GP::Timestamp.new(seconds: 3))
      expect_raises(Protobuf::Error) { any.unpack(GP::Duration) }
    end
  end

  describe "proto2" do
    it "prints groups and extensions" do
      message = P2.new(data: P2::Data.new(group_int32: 1))
      message.set_extension(ProtobufTestMessages::Proto2::EXTENSION_INT32, 7)
      text = message.to_json
      text.should eq(%({"data":{"groupInt32":1},"[protobuf_test_messages.proto2.extension_int32]":7}))
      P2.from_json(text).should eq(message)
    end

    it "prints MessageSet extensions" do
      set = P2::MessageSetCorrect.new
      set.set_extension(P2::MessageSetCorrectExtension1::MESSAGE_SET_EXTENSION, P2::MessageSetCorrectExtension1.new(str: "a"))
      message = P2.new(message_set_correct: set)
      text = message.to_json
      text.should eq(%({"messageSetCorrect":{"[protobuf_test_messages.proto2.TestAllTypesProto2.MessageSetCorrectExtension1.message_set_extension]":{"str":"a"}}}))
      P2.from_json(text).should eq(message)
    end

    it "rejects unknown and misplaced extensions" do
      expect_raises(Protobuf::JSON::ParseError, /Unknown field/) { P2.from_json(%({"[no.such]":1})) }
      expect_raises(Protobuf::JSON::ParseError, /Unknown field/) { P3.from_json(%({"[protobuf_test_messages.proto2.extension_int32]":1})) }
      expect_raises(Protobuf::JSON::ParseError, /Duplicate extension/) {
        P2.from_json(%({"[protobuf_test_messages.proto2.extension_int32]":1,"[protobuf_test_messages.proto2.extension_int32]":2}))
      }
    end

    it "prints required fields" do
      message = ProtobufTestMessages::Proto2::TestAllRequiredTypesProto2.new(required_int32: 0)
      JSON.parse(message.to_json)["requiredInt32"].should eq(0)
    end
  end
end
