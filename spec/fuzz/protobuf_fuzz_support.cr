# Mutation fuzzing of the protobuf runtime: the binary decoder, the JSON
# parser and printer, and the .proto tokenizer / parser / importer.
#
# Every target checks an error contract (only the documented exception may
# escape) and round-trip invariants on success. Used by the bounded,
# fixed-seed specs in spec/fuzz/*_fuzz_spec.cr and by the long randomized
# campaigns of script/fuzz_protobuf.sh (spec/fuzz/protobuf_fuzz.cr).
require "../../src/protobuf"
require "../../src/protobuf/compiler/importer"
require "../../src/protobuf/compiler/generator"
require "../protobuf/generated/google/protobuf/test_messages_proto3.pb"
require "../protobuf/generated/google/protobuf/test_messages_proto2.pb"
require "../protobuf/generated/conformance/conformance.pb"
require "../protobuf/generated/conformance/test_protos/test_messages_edition2023.pb"
require "../protobuf/generated/conformance/test_protos/test_messages_edition_unstable.pb"
require "../protobuf/generated/editions/golden/test_messages_proto2_editions.pb"
require "../protobuf/generated/editions/golden/test_messages_proto3_editions.pb"

module ProtobufFuzz
  ROOT = File.expand_path("../..", __DIR__)

  # A failed check: the target, the input and what went wrong.
  record Finding, target : String, input : Bytes, message : String

  # Message types fuzzed by the binary and JSON targets.
  MESSAGE_TYPES = [
    "protobuf_test_messages.proto3.TestAllTypesProto3",
    "protobuf_test_messages.proto2.TestAllTypesProto2",
    "protobuf_test_messages.editions.TestAllTypesEdition2023",
    "protobuf_test_messages.editions.proto2.TestAllTypesProto2",
    "protobuf_test_messages.editions.proto3.TestAllTypesProto3",
    "protobuf_test_messages.edition_unstable.TestAllTypesEditionUnstable",
    "protobuf_test_messages.proto2.TestAllRequiredTypesProto2",
    "google.protobuf.FileDescriptorSet",
    "google.protobuf.Struct",
    "google.protobuf.Any",
    "conformance.ConformanceRequest",
  ]

  # Byte-level mutations.
  class Mutator
    INTERESTING = [0x00, 0x01, 0x7f, 0x80, 0xff, 0x08, 0x0a, 0x0b, 0x0c, 0x12, 0x1a, 0x22, 0x30, 0x7b, 0x7d, 0x22, 0x5c]
    VARINTS     = [
      Bytes[0x80, 0x80, 0x80, 0x80, 0x10], Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01],
      Bytes[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f], Bytes[0x80, 0x00], Bytes[0xff, 0xff, 0xff, 0xff, 0x0f],
      Bytes[0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01],
    ]

    def initialize(@random : Random, @corpus : Array(Bytes))
    end

    def mutate(input : Bytes) : Bytes
      data = input.to_a
      (1 + @random.rand(4)).times { mutate_once(data) }
      Bytes.new(data.size) { |i| data[i] }
    end

    private def mutate_once(data : Array(UInt8)) : Nil
      case @random.rand(11)
      when 0 # flip a bit
        return if data.empty?
        i = @random.rand(data.size)
        data[i] ^= (1_u8 << @random.rand(8))
      when 1 # set an interesting byte
        return if data.empty?
        data[@random.rand(data.size)] = INTERESTING.sample(@random).to_u8
      when 2 # random byte
        return if data.empty?
        data[@random.rand(data.size)] = @random.rand(256).to_u8
      when 3 # insert bytes
        at = @random.rand(data.size + 1)
        (1 + @random.rand(4)).times { data.insert(at, @random.rand(256).to_u8) }
      when 4 # delete a range
        return if data.empty?
        at = @random.rand(data.size)
        data.delete_at(at, Math.min(1 + @random.rand(8), data.size - at))
      when 5 # duplicate a chunk
        return if data.empty?
        at = @random.rand(data.size)
        chunk = data[at, 1 + @random.rand(16)]
        data.insert_all(@random.rand(data.size + 1), chunk)
      when 6 # truncate
        data.pop(@random.rand(data.size + 1)) unless data.empty?
      when 7 # splice from the corpus
        other = @corpus.sample(@random)
        return if other.empty?
        from = @random.rand(other.size)
        chunk = other[from, Math.min(1 + @random.rand(32), other.size - from)].to_a
        data.insert_all(@random.rand(data.size + 1), chunk)
      when 8 # insert a pathological varint
        data.insert_all(@random.rand(data.size + 1), VARINTS.sample(@random).to_a)
      when 9 # swap two chunks
        return if data.size < 4
        a = @random.rand(data.size - 1)
        b = @random.rand(data.size - 1)
        data[a], data[b] = data[b], data[a]
      else # increment / decrement a byte (lengths, tags)
        return if data.empty?
        i = @random.rand(data.size)
        data[i] = data[i] &+ (@random.next_bool ? 1_u8 : 255_u8)
      end
    end
  end

  # Generates random but structurally valid wire data for a message type,
  # driven by the registered descriptors.
  class WireGenerator
    alias D = Google::Protobuf
    alias T = D::FieldDescriptorProto::Type

    def initialize(@random : Random)
    end

    def generate(type_name : String, depth : Int32 = 0) : Bytes
      io = IO::Memory.new
      write_message(Protobuf::Writer.new(io), type_name, depth)
      io.to_slice
    end

    private def write_message(writer : Protobuf::Writer, type_name : String, depth : Int32) : Nil
      descriptor = Protobuf::Registry.message_descriptor(type_name) || return
      file = Protobuf::Registry.file_containing_symbol(type_name)
      descriptor.field.each do |field|
        next if @random.rand < 0.55
        count = field.label == D::FieldDescriptorProto::Label::LABEL_REPEATED ? @random.rand(4) : 1
        count.times { write_field(writer, field, type_name, depth, file) }
      end
      Protobuf::Registry.extensions_of(type_name).each do |extension|
        next if @random.rand < 0.7
        if field = extension_descriptor(extension)
          write_field(writer, field, type_name, depth, Protobuf::Registry.file_containing_symbol(extension.full_name))
        end
      end
      if @random.rand < 0.1 # an unknown field
        writer.write_tag(19_999 - @random.rand(100), Protobuf::WireType::Varint)
        writer.write_varint(@random.rand(UInt64::MAX))
      end
    end

    private def extension_descriptor(extension : Protobuf::ExtensionField) : D::FieldDescriptorProto?
      symbol = Protobuf::Registry.symbol(extension.full_name) || return nil
      symbol.descriptor.as?(D::FieldDescriptorProto)
    end

    private def write_field(writer, field : D::FieldDescriptorProto, scope : String, depth : Int32, file) : Nil
      number = field.number || return
      type = field.type || return
      case type
      when .type_message?, .type_group?
        return if depth > 6
        nested = (field.type_name || "").lchop('.')
        delimited = type.type_group? || (file.try(&.syntax) == "editions" && delimited_feature?(field, file))
        if delimited
          writer.write_tag(number, Protobuf::WireType::StartGroup)
          write_message(writer, nested, depth + 1)
          writer.write_tag(number, Protobuf::WireType::EndGroup)
        else
          writer.write_tag(number, Protobuf::WireType::LengthDelimited)
          writer.write_length_prefixed(generate(nested, depth + 1))
        end
      when .type_string?
        writer.write_tag(number, Protobuf::WireType::LengthDelimited)
        writer.write_length_prefixed(random_string)
      when .type_bytes?
        writer.write_tag(number, Protobuf::WireType::LengthDelimited)
        writer.write_length_prefixed(Bytes.new(@random.rand(8)) { @random.rand(256).to_u8 })
      when .type_double?, .type_fixed64?, .type_sfixed64?
        writer.write_tag(number, Protobuf::WireType::Fixed64)
        writer.write_fixed64(@random.next_bool ? @random.rand(UInt64::MAX) : [0_u64, 1_u64, 0x7ff8000000000000_u64, 0x8000000000000000_u64].sample(@random))
      when .type_float?, .type_fixed32?, .type_sfixed32?
        writer.write_tag(number, Protobuf::WireType::Fixed32)
        writer.write_fixed32(@random.rand(UInt32::MAX))
      else
        if field.label == D::FieldDescriptorProto::Label::LABEL_REPEATED && @random.next_bool
          writer.write_length_delimited(number) do |packed|
            (1 + @random.rand(4)).times { packed.write_varint(random_varint(type, field)) }
          end
        else
          writer.write_tag(number, Protobuf::WireType::Varint)
          writer.write_varint(random_varint(type, field))
        end
      end
    end

    private def delimited_feature?(field, file) : Bool
      encoding = field.options.try(&.features).try(&.message_encoding) ||
                 file.try(&.options).try(&.features).try(&.message_encoding)
      encoding == D::FeatureSet::MessageEncoding::DELIMITED
    end

    private def random_varint(type : T, field : D::FieldDescriptorProto) : UInt64
      case @random.rand(6)
      when 0 then 0_u64
      when 1 then 1_u64
      when 2 then UInt64::MAX
      when 3 then @random.rand(300).to_u64
      when 4 then (-1_i64).to_u64!
      else        @random.rand(UInt64::MAX)
      end
    end

    private def random_string : Bytes
      chars = ["a", "é", "中", "😀", "\u0000", "\"", "\\"]
      text = String.build { |io| @random.rand(6).times { io << chars.sample(@random) } }
      bytes = text.to_slice.dup
      if @random.rand < 0.05 && !bytes.empty? # invalid UTF-8
        bytes[@random.rand(bytes.size)] = 0xff_u8
      end
      bytes
    end
  end

  # Runs fuzz targets and collects findings.
  class Campaign
    getter findings = [] of Finding
    getter executions = 0
    getter accepted = Hash(String, Int32).new(0)
    getter rejected = Hash(String, Int32).new(0)
    property slow_threshold : Time::Span = 2.seconds

    def initialize(@seed : UInt64)
      @random = Random.new(@seed)
    end

    # --- Binary decoder ---

    def binary_corpus : Array({String, Bytes})
      generator = WireGenerator.new(Random.new(@seed &+ 1))
      corpus = [] of {String, Bytes}
      MESSAGE_TYPES.each do |type|
        corpus << {type, Bytes.empty}
        6.times { corpus << {type, generator.generate(type)} }
      end
      corpus
    end

    def fuzz_binary(iterations : Int32) : Nil
      corpus = binary_corpus
      mutator = Mutator.new(@random, corpus.map(&.[1]))
      iterations.times do
        type, seed = corpus.sample(@random)
        check_binary(type, @random.rand < 0.1 ? seed : mutator.mutate(seed))
      end
    end

    # Checks the binary decoder's contract on *input*: either a
    # `Protobuf::DecodeError`, or a message whose encoding re-decodes to the
    # same encoding (and whose JSON form, if printable, re-parses to the
    # same JSON).
    def check_binary(type_name : String, input : Bytes) : Nil
      klass = Protobuf::Registry.message_class(type_name)
      timed("binary", input) do
        message = begin
          klass.from_protobuf(input)
        rescue Protobuf::DecodeError
          @rejected["binary"] += 1
          next
        end
        @accepted["binary"] += 1
        encoded = message.to_protobuf
        again = klass.from_protobuf(encoded)
        unless again.to_protobuf == encoded
          fail("binary", input, "#{type_name}: re-encoding is not stable")
          next
        end
        check_json_round_trip("binary", type_name, message, input)
      end
    end

    private def check_json_round_trip(target : String, type_name : String, message : Protobuf::Message, input : Bytes) : Nil
      klass = Protobuf::Registry.message_class(type_name)
      json = begin
        message.to_json(Protobuf::JSON::PrintOptions.new)
      rescue Protobuf::JSON::SerializeError
        return
      end
      parsed = begin
        klass.from_json(json, Protobuf::JSON::ParseOptions.new)
      rescue ex : Protobuf::JSON::ParseError
        fail(target, input, "#{type_name}: printed JSON does not parse: #{ex.message}\n#{json[0, 500]}")
        return
      end
      # Printing may normalize once (an unknown NullValue prints as null and
      # parses back as NULL_VALUE); after that, JSON must be a fixpoint.
      reprinted = parsed.to_json(Protobuf::JSON::PrintOptions.new)
      again = klass.from_json(reprinted, Protobuf::JSON::ParseOptions.new).to_json(Protobuf::JSON::PrintOptions.new)
      fail(target, input, "#{type_name}: JSON round trip is not stable\n#{reprinted}\n#{again}") unless again == reprinted
      # Also with every printing option.
      options = Protobuf::JSON::PrintOptions.new(emit_defaults: true, preserve_proto_field_names: true, enums_as_ints: true)
      verbose = parsed.to_json(options)
      unless klass.from_json(verbose, Protobuf::JSON::ParseOptions.new).to_json(options) == verbose
        fail(target, input, "#{type_name}: JSON round trip with options is not stable")
      end
    rescue ex : Protobuf::JSON::SerializeError
      # A message that printed once may still hold unprintable values.
    end

    # --- JSON parser ---

    JSON_SEEDS = [
      %({"optionalInt32":1,"optionalInt64":"-2","optionalUint64":"18446744073709551615","optionalFloat":"NaN","optionalDouble":1e300}),
      %({"optionalString":"é\\u0000\\ud83d\\ude00","optionalBytes":"AQID","optionalBool":true,"optionalNestedEnum":"BAZ"}),
      %({"repeatedInt32":[1,2,3],"repeatedString":["a",""],"mapStringString":{"a":"b"},"mapInt32Int32":{"-1":1},"mapBoolBool":{"true":false}}),
      %({"optionalNestedMessage":{"a":1,"corecursive":{"optionalInt32":2}},"oneofUint32":0}),
      %({"optionalDuration":"1.5s","optionalTimestamp":"1970-01-01T00:00:00.1Z","optionalFieldMask":"fooBar,baz"}),
      %({"optionalStruct":{"a":[1,"x",null,{"b":true}]},"optionalValue":null,"repeatedValue":[1,[]],"optionalNullValue":null}),
      %({"optionalAny":{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1s"},"optionalInt64Wrapper":"3","optionalBytesWrapper":"AA=="}),
      %({"optionalAny":{"@type":"type.googleapis.com/protobuf_test_messages.proto3.TestAllTypesProto3","optionalInt32":5,"optionalAny":{"@type":"type.googleapis.com/google.protobuf.Empty"}}}),
      %({"recursiveMessage":{"recursiveMessage":{"optionalString":"deep"}},"fieldName7":1,"FieldName8":2,"field_Name9":3}),
      %({"optional_int32":5,"unknownField":{"x":[1,2]},"optionalAliasedEnum":"moo","repeatedNestedEnum":[0,"BAR",-1]}),
      %({"data":{"groupInt32":1},"[protobuf_test_messages.proto2.extension_int32]":5,"messageSetCorrect":{"[protobuf_test_messages.proto2.TestAllTypesProto2.MessageSetCorrectExtension1.message_set_extension]":{"str":"a"}}}),
      %({"optionalFloat":3.4028235e38,"optionalDouble":-0,"repeatedFloat":["Infinity","-Infinity",1.5e-45],"optionalInt32":"1e2"}),
    ]

    JSON_TOKENS = ["{", "}", "[", "]", ",", ":", "\"", "null", "true", "false", "0", "-1", "1e5", "1.5", "\"NaN\"", "\"Infinity\"",
                   "\\u0000", "\\ud800", "\"a\":", "{}", "[]", "18446744073709551616", "\"@type\"", "9e999", "\"\\\"",
                   "\"optionalInt32\":", "\"optionalAny\":", "\"optionalValue\":", "\"oneofString\":", "\"[protobuf_test_messages.proto2.extension_int32]\":"]

    def fuzz_json(iterations : Int32) : Nil
      types = ["protobuf_test_messages.proto3.TestAllTypesProto3", "protobuf_test_messages.proto2.TestAllTypesProto2",
               "protobuf_test_messages.editions.proto3.TestAllTypesProto3", "google.protobuf.Value", "google.protobuf.Any"]
      corpus = JSON_SEEDS.map(&.to_slice)
      mutator = Mutator.new(@random, corpus)
      iterations.times do
        seed = JSON_SEEDS.sample(@random)
        text = case @random.rand(3)
               when 0 then String.new(mutator.mutate(seed.to_slice))
               when 1 then mutate_json_tokens(seed)
               else        seed
               end
        check_json(types.sample(@random), text)
      end
    end

    private def mutate_json_tokens(text : String) : String
      chars = text.chars
      (1 + @random.rand(3)).times do
        at = @random.rand(chars.size + 1)
        case @random.rand(3)
        when 0 then chars.insert_all(at, JSON_TOKENS.sample(@random).chars)
        when 1 then chars.delete_at(at, Math.min(1 + @random.rand(6), chars.size - at)) if at < chars.size
        else
          if at < chars.size
            chars.delete_at(at, Math.min(1 + @random.rand(4), chars.size - at))
            chars.insert_all(at, JSON_TOKENS.sample(@random).chars)
          end
        end
      end
      chars.join
    end

    # Checks the JSON parser's contract on *text*: either a
    # `Protobuf::JSON::ParseError`, or a message that survives binary and
    # JSON round trips.
    def check_json(type_name : String, text : String) : Nil
      klass = Protobuf::Registry.message_class(type_name)
      timed("json", text.to_slice) do
        [false, true].each do |ignore|
          message = begin
            klass.from_json(text, Protobuf::JSON::ParseOptions.new(ignore_unknown_fields: ignore))
          rescue Protobuf::JSON::ParseError
            @rejected["json"] += 1
            next
          end
          @accepted["json"] += 1
          encoded = message.to_protobuf
          unless klass.from_protobuf(encoded).to_protobuf == encoded
            fail("json", text.to_slice, "#{type_name}: binary re-encoding of parsed JSON is not stable")
          end
          check_json_round_trip("json", type_name, message, text.to_slice)
        end
      end
    end

    # --- .proto parser ---

    PROTO_SEEDS = {
      "proto3.proto" => <<-PROTO,
        syntax = "proto3";
        package fuzz.p3;
        import "google/protobuf/timestamp.proto";
        option java_package = "x";
        // A message.
        message M {
          int32 a = 1 [deprecated = true, json_name = "aa"];
          optional string b = 2;
          repeated M children = 3;
          map<string, int64> m = 4;
          oneof o { bytes c = 5; google.protobuf.Timestamp t = 6; }
          enum E { E_ZERO = 0; E_ONE = 1 [deprecated = true]; }
          E e = 7;
          reserved 10 to 20, 30;
          reserved "x";
        }
        service S { rpc R(M) returns (stream M) { option deprecated = true; } }
        PROTO
      "proto2.proto" => <<-PROTO,
        syntax = "proto2";
        package fuzz.p2;
        import "google/protobuf/descriptor.proto";
        message N {
          required int32 a = 1 [default = -0x10];
          optional double d = 2 [default = -inf];
          optional bytes b = 3 [default = "\\001\\x02"];
          optional group G = 4 { optional int32 x = 5; }
          extensions 100 to max;
        }
        extend N { optional string note = 100; }
        extend google.protobuf.FieldOptions { optional N rule = 50000; repeated int32 nums = 50001; }
        message O { optional int32 v = 1 [(rule) = { a: 1 G { x: 2 } [fuzz.p2.note]: "n" }, (nums) = 1]; }
        PROTO
      "editions.proto" => <<-PROTO,
        edition = "2024";
        package fuzz.ed;
        option features.field_presence = IMPLICIT;
        export message E {
          int32 a = 1 [features.field_presence = EXPLICIT];
          local message L { string s = 1; }
          L l = 2 [features.message_encoding = DELIMITED];
          repeated int32 r = 3 [features.repeated_field_encoding = EXPANDED];
          reserved field_x;
        }
        local enum Z { option features.enum_type = CLOSED; Z_ONE = 1; }
        PROTO
    }

    PROTO_TOKENS = ["{", "}", ";", "=", "[", "]", "(", ")", "<", ">", ",", ".", "message", "enum", "optional", "repeated",
                    "required", "group", "oneof", "map<", "extend", "extensions", "reserved", "option", "import", "package",
                    "syntax", "edition", "\"proto2\"", "\"2023\"", "1", "-1", "0x7fffffff", "536870912", "19000", "max", "to",
                    "inf", "nan", "\"str\"", "'\\x", "/*", "*/", "//", "\n", "int32", "string", "bytes", "M", "N", ".fuzz.p3.M",
                    "default", "json_name", "features.", "(rule)", "{ a: 1 }", "stream", "rpc", "returns", "export", "local"]

    def fuzz_proto(iterations : Int32) : Nil
      corpus = PROTO_SEEDS.values.map(&.to_slice)
      mutator = Mutator.new(@random, corpus)
      iterations.times do
        name, source = PROTO_SEEDS.to_a.sample(@random)
        mutated = case @random.rand(3)
                  when 0 then String.new(mutator.mutate(source.to_slice))
                  when 1 then mutate_proto_tokens(source)
                  else        mutate_proto_tokens(String.new(mutator.mutate(source.to_slice)))
                  end
        check_proto(name, mutated)
      end
    end

    private def mutate_proto_tokens(source : String) : String
      words = source.scrub.split(/(\s+)/)
      (1 + @random.rand(3)).times do
        at = @random.rand(words.size + 1)
        case @random.rand(3)
        when 0 then words.insert(at, " #{PROTO_TOKENS.sample(@random)} ")
        when 1 then words.delete_at(at) if at < words.size
        else        words[at] = PROTO_TOKENS.sample(@random) if at < words.size
        end
      end
      words.join
    end

    # Checks the tokenizer, parser, importer and generator on *source*:
    # only `Protobuf::Compiler::ParseError` (or `Generator::Error`) may be
    # raised.
    def check_proto(name : String, source : String) : Nil
      timed("proto", source.to_slice) do
        begin
          Protobuf::Compiler::Tokenizer.tokenize(source, name)
          Protobuf::Compiler::Parser.parse(source, name)
        rescue Protobuf::Compiler::ParseError
        end
        sources = PROTO_SEEDS.dup
        sources[name] = source
        request = begin
          Protobuf::Compiler::Importer.new([] of String, sources: sources).code_generator_request([name])
        rescue Protobuf::Compiler::ParseError
          @rejected["proto"] += 1
          next
        end
        @accepted["proto"] += 1
        response = Protobuf::Compiler::Generator.call(request)
        if response.error.nil?
          begin
            Protobuf::Compiler::Generator.new(request).generate_inline
          rescue Protobuf::Compiler::Generator::Error
          end
        end
      end
    end

    # --- Helpers ---

    private def timed(target : String, input : Bytes, &) : Nil
      @executions += 1
      started = Time.instant
      begin
        yield
      rescue ex
        fail(target, input, "#{ex.class}: #{ex.message}\n#{ex.backtrace?.try(&.first(6).join("\n"))}")
      end
      elapsed = Time.instant - started
      fail(target, input, "slow input: #{elapsed.total_milliseconds.round}ms") if elapsed > @slow_threshold
    end

    private def fail(target : String, input : Bytes, message : String) : Nil
      @findings << Finding.new(target, input, message)
    end
  end
end
