require "./protobuf_helper"
require "../../src/protobuf/compiler/importer"

private alias Compiler = Protobuf::Compiler

# Protos for which the parser path must reproduce protoc's descriptors
# exactly, as observed through the generated code. Each entry is an
# include directory (relative to the project root) and the files to
# generate.
private EQUIVALENCE_CASES = [
  {"spec/protobuf/proto", %w(google/protobuf/test_messages_proto3.proto)},
  {"spec/protobuf/proto", %w(google/protobuf/test_messages_proto2.proto)},
  {"spec/protobuf/proto", %w(spec_test/types.proto spec_test/sub/imported.proto)},
  {"spec/protobuf/proto", %w(spec_test/proto2.proto)},
  {"spec/protobuf/proto", %w(spec_test/editions.proto spec_test/editions_implicit.proto)},
  {"spec/protobuf/proto", %w(spec_test/service.proto)},
  {"spec/protobuf/proto", %w(parser_test/torture.proto)},
  {"spec/protobuf/proto", %w(parser_test/proto3.proto)},
  {"spec/protobuf/proto", %w(parser_test/editions.proto)},
  {"spec/protobuf/proto", %w(parser_test/options/usage.proto parser_test/options/proto2.proto parser_test/options/edition2024.proto)},
  {"spec/protobuf/proto", %w(conformance/conformance.proto conformance/test_protos/test_messages_edition2023.proto)},
  {"spec/protobuf/proto", %w(editions/golden/test_messages_proto2_editions.proto editions/golden/test_messages_proto3_editions.proto)},
  {"spec/interop/proto", %w(src/proto/grpc/testing/test.proto src/proto/grpc/testing/messages.proto src/proto/grpc/testing/empty.proto)},
  {"spec/grpc/proto", %w(test_service.proto)},
  {"src/grpc/health/proto", %w(grpc/health/v1/health.proto)},
  {"examples/helloworld/proto", %w(helloworld.proto)},
  {"src/protobuf/proto", ProtobufSpec::WELL_KNOWN_PROTOS},
]

private def parse(source : String, name = "test.proto") : Google::Protobuf::FileDescriptorProto
  Compiler::Parser.parse(source, name)
end

private def leading_comments(source : String) : Hash(Array(Int32), String)
  info = parse(source).source_code_info.not_nil!
  info.location.compact_map { |location| {location.path, location.leading_comments.not_nil!} if location.leading_comments }.to_h
end

private def expect_parse_error(source : String, message : String | Regex, line : Int32? = nil, column : Int32? = nil, file = __FILE__, spec_line = __LINE__)
  error = expect_raises(Compiler::ParseError, file: file, line: spec_line) { parse(source) }
  case message
  in String then error.description.should eq(message), file: file, line: spec_line
  in Regex  then error.description.should match(message), file: file, line: spec_line
  end
  error.line.should eq(line), file: file, line: spec_line if line
  error.column.should eq(column), file: file, line: spec_line if column
end

# Writes *files* (name => source) into a fresh directory and returns it.
private def proto_tree(files : Hash(String, String)) : String
  dir = ProtobufSpec.tmp_path("tree")
  files.each do |name, source|
    path = File.join(dir, name)
    Dir.mkdir_p(File.dirname(path))
    File.write(path, source)
  end
  dir
end

private def link(files : Hash(String, String), names : Array(String)) : Google::Protobuf::Compiler::CodeGeneratorRequest
  dir = proto_tree(files)
  Compiler::Importer.new([dir]).code_generator_request(names)
end

describe Compiler::Parser do
  describe "equivalence with protoc" do
    EQUIVALENCE_CASES.each do |(include_dir, names)|
      it "generates identical code for #{names.join(", ")}" do
        skip_without_protoc
        root = ProtobufSpec::ROOT
        include_path = File.join(root, include_dir)
        expected = ProtobufSpec.files(ProtobufSpec.generate(names, include_dirs: ["-I#{include_path}"]))
        request = Compiler::Importer.new([include_path]).code_generator_request(names)
        actual = ProtobufSpec.files(Compiler::Generator.call(request))
        actual.keys.sort.should eq(expected.keys.sort)
        expected.each do |name, content|
          actual[name].should eq(content)
        end
      end
    end

    it "generates the same message and service definitions inline as in plugin files" do
      dir = File.join(ProtobufSpec::ROOT, "examples/helloworld/proto")
      request = Compiler::Importer.new([dir]).code_generator_request(["helloworld.proto"])
      files = ProtobufSpec.files(Compiler::Generator.call(request))
      inline = Compiler::Generator.new(request).generate_inline
      # Drop the file header and requires: everything before the first
      # definition.
      body = ->(content : String) do
        lines = content.lines(chomp: false)
        lines[(lines.index { |l| l.starts_with?("module ") || l.starts_with?("class ") || l.starts_with?("enum ") }.not_nil!)..].join
      end
      inline.should contain(body.call(files["helloworld.pb.cr"]))
      inline.should contain(body.call(files["helloworld_grpc.pb.cr"]))
    end
  end

  describe "syntax" do
    it "parses syntax, package and imports" do
      file = parse(%(syntax = "proto3";\npackage a.b.c;\nimport "x.proto";\nimport public "y.proto";\nimport weak "z.proto";\n))
      file.syntax.should eq("proto3")
      file.package.should eq("a.b.c")
      file.dependency.should eq(["x.proto", "y.proto", "z.proto"])
      file.public_dependency.should eq([1])
      file.weak_dependency.should eq([2])
    end

    it "defaults to proto2 without a syntax statement" do
      file = parse(%(message M { optional int32 a = 1; }))
      file.syntax.should be_nil
      file.message_type[0].field[0].label.should eq(Google::Protobuf::FieldDescriptorProto::Label::LABEL_OPTIONAL)
    end

    it "parses editions" do
      file = parse(%(edition = "2023";\noption features.field_presence = IMPLICIT;\nmessage M { int32 a = 1 [features.field_presence = EXPLICIT]; }))
      file.syntax.should eq("editions")
      file.edition.should eq(Google::Protobuf::Edition::EDITION_2023)
      file.options.not_nil!.features.not_nil!.field_presence.should eq(Google::Protobuf::FeatureSet::FieldPresence::IMPLICIT)
      file.message_type[0].field[0].options.not_nil!.features.not_nil!.field_presence.should eq(Google::Protobuf::FeatureSet::FieldPresence::EXPLICIT)
    end

    it "parses numeric literals and string escapes" do
      file = parse(<<-PROTO)
        syntax = "proto2";
        enum E { A = 0; B = -1; C = 0x1F; D = 017; }
        message M { optional string s = 1 [default = "a\\tb\\x41\\101\\u00e9" "c"]; optional double d = 2 [default = -inf]; }
        PROTO
      file.enum_type[0].value.map(&.number).should eq([0, -1, 31, 15])
      field = file.message_type[0].field[0]
      field.default_value.should eq("a\tbAAéc")
      file.message_type[0].field[1].default_value.should eq("-inf")
    end

    it "synthesizes map entry messages like protoc" do
      file = parse(%(syntax = "proto3";\nmessage M { map<string, int32> my_map = 1; }))
      message = file.message_type[0]
      entry = message.nested_type[0]
      entry.name.should eq("MyMapEntry")
      entry.options.not_nil!.map_entry.should be_true
      entry.field.map(&.name).should eq(["key", "value"])
      message.field[0].label.should eq(Google::Protobuf::FieldDescriptorProto::Label::LABEL_REPEATED)
      message.field[0].type_name.should eq("MyMapEntry")
    end

    it "adds synthetic oneofs for proto3 optional fields after real oneofs" do
      file = parse(%(syntax = "proto3";\nmessage M { optional int32 a = 1; oneof o { int32 b = 2; } }))
      message = file.message_type[0]
      message.oneof_decl.map(&.name).should eq(["o", "_a"])
      message.field[0].proto3_optional.should be_true
      message.field[0].oneof_index.should eq(1)
      message.field[1].oneof_index.should eq(0)
    end

    it "parses proto2 groups into a field and a nested message" do
      file = parse(%(message M { repeated group Item = 1 { optional int32 x = 2; } }))
      message = file.message_type[0]
      message.field[0].name.should eq("item")
      message.field[0].type.should eq(Google::Protobuf::FieldDescriptorProto::Type::TYPE_GROUP)
      message.nested_type[0].name.should eq("Item")
    end

    it "parses services with streaming and option blocks" do
      file = parse(%(syntax = "proto3";\nservice S {\n  rpc A (stream X) returns (stream .p.Y) { option deprecated = true; }\n  rpc B (X) returns (X);\n}))
      methods = file.service[0].method
      methods[0].client_streaming.should be_true
      methods[0].server_streaming.should be_true
      methods[0].output_type.should eq(".p.Y")
      methods[1].client_streaming.should be_nil
    end

    it "records extension ranges, reserved ranges and extend blocks like protoc" do
      file = parse(<<-PROTO)
        syntax = "proto2";
        option (my_opt) = { a: 1 nested { b: [1, 2] } };
        message M {
          extensions 100 to max;
          extensions 10, 20 to 30;
          reserved 2, 5 to 9;
          reserved "x", "y";
          optional int32 a = 1;
          enum E { A = 1; reserved -5 to -1, 10 to max; reserved "B"; }
        }
        message S { option message_set_wire_format = true; extensions 4 to max; }
        extend M { optional int32 ext = 100; }
        PROTO
      message = file.message_type[0]
      message.extension_range.map { |r| {r.start, r.end_} }.should eq([{100, 536870912}, {10, 11}, {20, 31}])
      message.reserved_range.map { |r| {r.start, r.end_} }.should eq([{2, 3}, {5, 10}])
      message.reserved_name.should eq(["x", "y"])
      message.enum_type[0].reserved_range.map { |r| {r.start, r.end_} }.should eq([{-5, -1}, {10, Int32::MAX}])
      message.enum_type[0].reserved_name.should eq(["B"])
      file.message_type[1].extension_range[0].end_.should eq(Int32::MAX)
      file.extension[0].extendee.should eq("M")
      # Custom options are left uninterpreted until imports are resolved.
      file.options.not_nil!.uninterpreted_option[0].name[0].name_part.should eq("my_opt")
      file.options.not_nil!.uninterpreted_option[0].aggregate_value.should eq("a : 1 nested { b : [ 1 , 2 ] }")
    end

    it "interprets standard options of every kind" do
      file = parse(<<-PROTO)
        syntax = "proto3";
        option java_package = "p";
        option optimize_for = LITE_RUNTIME;
        option cc_enable_arenas = true;
        message M {
          option deprecated = true;
          int32 a = 1 [deprecated = true, jstype = JS_STRING, packed = false, retention = RETENTION_RUNTIME];
        }
        enum E { option allow_alias = true; X = 0 [deprecated = true]; Y = 0; }
        service S { option deprecated = true; rpc R(M) returns (M) { option idempotency_level = IDEMPOTENT; } }
        PROTO
      options = file.options.not_nil!
      options.java_package.should eq("p")
      options.optimize_for.should eq(Google::Protobuf::FileOptions::OptimizeMode::LITE_RUNTIME)
      options.cc_enable_arenas.should be_true
      options.uninterpreted_option.should be_empty
      field = file.message_type[0].field[0].options.not_nil!
      field.deprecated.should be_true
      field.jstype.should eq(Google::Protobuf::FieldOptions::JSType::JS_STRING)
      field.packed.should be_false
      file.enum_type[0].options.not_nil!.allow_alias.should be_true
      file.enum_type[0].value[0].options.not_nil!.deprecated.should be_true
      file.service[0].options.not_nil!.deprecated.should be_true
      file.service[0].method[0].options.not_nil!.idempotency_level.should eq(Google::Protobuf::MethodOptions::IdempotencyLevel::IDEMPOTENT)
    end

    it "parses edition 2024 visibility modifiers and option imports" do
      file = parse(<<-PROTO)
        edition = "2024";
        import option "opts.proto";
        export message A { local message B {} }
        local enum E { E_ZERO = 0; }
        PROTO
      file.option_dependency.should eq(["opts.proto"])
      file.dependency.should be_empty
      file.message_type[0].visibility.should eq(Google::Protobuf::SymbolVisibility::VISIBILITY_EXPORT)
      file.message_type[0].nested_type[0].visibility.should eq(Google::Protobuf::SymbolVisibility::VISIBILITY_LOCAL)
      file.enum_type[0].visibility.should eq(Google::Protobuf::SymbolVisibility::VISIBILITY_LOCAL)
    end

    it "parses editions 2026 and UNSTABLE" do
      parse(%(edition = "2026";\nmessage M { int32 a = 1; })).edition.should eq(Google::Protobuf::Edition::EDITION_2026)
      file = parse(%(edition = "UNSTABLE";\nmessage M { int32 a = 1; uint64 b = 2; varint32 c = 3; zigzag64 d = 4; map<int32, uvarint32> m = 5; }))
      file.edition.should eq(Google::Protobuf::Edition::EDITION_UNSTABLE)
      types = file.message_type[0].field.map(&.type)
      types[0..3].should eq([Google::Protobuf::FieldDescriptorProto::Type::TYPE_SFIXED32, Google::Protobuf::FieldDescriptorProto::Type::TYPE_FIXED64,
                             Google::Protobuf::FieldDescriptorProto::Type::TYPE_INT32, Google::Protobuf::FieldDescriptorProto::Type::TYPE_SINT64])
      file.message_type[0].nested_type[0].field.map(&.type).should eq([Google::Protobuf::FieldDescriptorProto::Type::TYPE_SFIXED32,
                                                                       Google::Protobuf::FieldDescriptorProto::Type::TYPE_UINT32])
      expect_parse_error(%(edition = "UNSTABLE";\nmessage M { sint32 a = 1; }), "Type 'sint32' is obsolete in unstable editions, use 'zigzag32' instead.", 2, 13)
    end
  end

  describe "comments" do
    it "attaches leading comments to declarations" do
      comments = leading_comments(<<-PROTO)
        syntax = "proto3";

        // Message comment
        // over two lines.
        message M {
          // Field comment.
          int32 a = 1;
          /* Block
           * comment. */
          int32 b = 2;
        }
        PROTO
      comments[[4, 0]].should eq(" Message comment\n over two lines.\n")
      comments[[4, 0, 2, 0]].should eq(" Field comment.\n")
      comments[[4, 0, 2, 1]].should eq(" Block\n comment. ")
    end

    it "does not attach comments separated by a blank line" do
      comments = leading_comments(%(syntax = "proto3";\n\n// Detached.\n\nmessage M {}\n))
      comments[[4, 0]]?.should be_nil
    end

    it "treats a comment on the previous token's line as trailing" do
      comments = leading_comments(%(syntax = "proto3";\nmessage M {\n  int32 a = 1; // trailing for a\n  int32 b = 2;\n}\n))
      comments[[4, 0, 2, 1]]?.should be_nil
    end

    it "treats a comment block followed by a blank line as trailing" do
      comments = leading_comments(%(syntax = "proto3";\nmessage M {\n  int32 a = 1;\n  // trailing for a\n\n  int32 b = 2;\n}\n))
      comments[[4, 0, 2, 1]]?.should be_nil
    end

    it "does not attach a comment to a closing brace" do
      comments = leading_comments(%(syntax = "proto3";\n// Leading.\nmessage M {\n  int32 a = 1;\n  // dangling\n}\n))
      comments.should eq({[4, 0] => " Leading.\n"})
    end
  end

  describe "errors" do
    it "reports syntax errors with line and column" do
      expect_parse_error(%(syntax = "proto3";\nmessage M {\n  int32 a = 1\n  int32 b = 2;\n}), %(Expected ";", found "int32".), 4, 3)
    end

    it "rejects unknown syntax versions" do
      expect_parse_error(%(syntax = "proto4";), /Unrecognized syntax identifier "proto4"/, 1, 10)
    end

    it "requires labels in proto2" do
      expect_parse_error(%(message M { int32 a = 1; }), %(Expected "required", "optional", or "repeated".), 1, 13)
    end

    it "rejects required fields in proto3" do
      expect_parse_error(%(syntax = "proto3";\nmessage M { required int32 a = 1; }), "Required fields are not allowed in proto3.", 2, 13)
    end

    it "rejects invalid field numbers" do
      expect_parse_error(%(syntax = "proto3";\nmessage M { int32 a = 0; }), /Field numbers must be positive/)
      expect_parse_error(%(syntax = "proto3";\nmessage M { int32 a = 19000; }), /reserved for the protocol buffer library/)
    end

    it "rejects duplicate field numbers and names" do
      expect_parse_error(%(syntax = "proto3";\nmessage M {\n  int32 a = 1;\n  int32 b = 1;\n}), /Field number 1 has already been used/, 4, 3)
      expect_parse_error(%(syntax = "proto3";\nmessage M {\n  int32 a = 1;\n  int32 a = 2;\n}), /"a" is already defined/, 4, 3)
    end

    it "requires proto3 enums to start at zero" do
      expect_parse_error(%(syntax = "proto3";\nenum E { A = 1; }), "The first enum value must be zero for open enums.")
    end

    it "rejects invalid map keys" do
      expect_parse_error(%(syntax = "proto3";\nmessage M { map<double, int32> m = 1; }), /Key in map fields cannot be/)
    end

    it "rejects unterminated strings and comments" do
      expect_parse_error(%(syntax = "proto3), "Unexpected end of string.", 1, 10)
      expect_parse_error(%(syntax = "proto3";\n/* never closed), "End-of-file inside block comment.", 2, 1)
    end

    it "reports a missing closing brace" do
      expect_parse_error(%(syntax = "proto3";\nmessage M {\n  int32 a = 1;\n), /Reached end of input in message definition/)
    end
  end
end

describe Compiler::Importer do
  it "resolves types using protobuf scoping rules" do
    request = link({"a.proto" => <<-PROTO}, ["a.proto"])
      syntax = "proto3";
      package p.q;
      message Outer {
        message Inner { Inner self = 1; }
        Inner inner = 1;
        Outer.Inner qualified = 2;
        .p.q.Outer.Inner absolute = 3;
        q.Outer partial = 4;
        Kind kind = 5;
        enum Kind { K = 0; }
      }
      PROTO
    message = request.proto_file[0].message_type[0]
    message.field.map(&.type_name).should eq([".p.q.Outer.Inner", ".p.q.Outer.Inner", ".p.q.Outer.Inner", ".p.q.Outer", ".p.q.Outer.Kind"])
    message.field[4].type.should eq(Google::Protobuf::FieldDescriptorProto::Type::TYPE_ENUM)
    message.nested_type[0].field[0].type_name.should eq(".p.q.Outer.Inner")
  end

  it "searches the innermost scope first like protoc" do
    error = expect_raises(Compiler::ParseError) do
      link({"a.proto" => <<-PROTO}, ["a.proto"])
        syntax = "proto3";
        package foo;
        message Bar { int32 x = 1; }
        message M {
          message foo {}
          foo.Bar b = 1;
        }
        PROTO
    end
    error.description.should contain(%("foo.Bar" is resolved to "foo.M.foo.Bar", which is not defined))
    error.line.should eq(6)
  end

  it "loads imports from include paths and the bundled well-known types" do
    request = link({
      "main.proto"    => %(syntax = "proto3";\nimport "dir/dep.proto";\nimport "google/protobuf/timestamp.proto";\nmessage M { d.Dep dep = 1; google.protobuf.Timestamp at = 2; }),
      "dir/dep.proto" => %(syntax = "proto3";\npackage d;\nmessage Dep {}),
    }, ["main.proto"])
    request.proto_file.map(&.name).should eq(["dir/dep.proto", "google/protobuf/timestamp.proto", "main.proto"])
    request.proto_file[2].message_type[0].field.map(&.type_name).should eq([".d.Dep", ".google.protobuf.Timestamp"])
  end

  it "makes types of public imports visible transitively" do
    request = link({
      "main.proto"  => %(syntax = "proto3";\nimport "relay.proto";\nmessage M { Deep d = 1; }),
      "relay.proto" => %(syntax = "proto3";\nimport public "deep.proto";),
      "deep.proto"  => %(syntax = "proto3";\nmessage Deep {}),
    }, ["main.proto"])
    request.proto_file.last.message_type[0].field[0].type_name.should eq(".Deep")
  end

  it "rejects types from files that are not imported" do
    error = expect_raises(Compiler::ParseError) do
      link({
        "main.proto"  => %(syntax = "proto3";\nimport "relay.proto";\nmessage M { Deep d = 1; }),
        "relay.proto" => %(syntax = "proto3";\nimport "deep.proto";),
        "deep.proto"  => %(syntax = "proto3";\nmessage Deep {}),
      }, ["main.proto"])
    end
    error.description.should contain(%("Deep" seems to be defined in "deep.proto", which is not imported by "main.proto"))
    error.filename.should end_with("main.proto")
    error.line.should eq(3)
  end

  it "reports missing imports at the import statement" do
    error = expect_raises(Compiler::ParseError) do
      link({"main.proto" => %(syntax = "proto3";\n\nimport "missing.proto";)}, ["main.proto"])
    end
    error.description.should contain(%(Import "missing.proto" was not found))
    error.line.should eq(3)
    error.column.should eq(1)
  end

  it "detects import cycles" do
    error = expect_raises(Compiler::ParseError) do
      link({
        "a.proto" => %(syntax = "proto3";\nimport "b.proto";),
        "b.proto" => %(syntax = "proto3";\nimport "a.proto";),
      }, ["a.proto"])
    end
    error.description.should contain("File recursively imports itself: a.proto -> b.proto -> a.proto")
  end

  it "rejects duplicate definitions across files" do
    error = expect_raises(Compiler::ParseError) do
      link({
        "a.proto" => %(syntax = "proto3";\nimport "b.proto";\nmessage Dup {}),
        "b.proto" => %(syntax = "proto3";\nmessage Dup {}),
      }, ["a.proto"])
    end
    error.description.should contain(%("Dup" is already defined in file "b.proto"))
  end

  it "rejects undefined types and non-message RPC types" do
    expect_raises(Compiler::ParseError, /"Nope" is not defined/) do
      link({"a.proto" => %(syntax = "proto3";\nmessage M { Nope n = 1; })}, ["a.proto"])
    end
    expect_raises(Compiler::ParseError, /"E" is not a message type/) do
      link({"a.proto" => %(syntax = "proto3";\nenum E { Z = 0; }\nmessage M {}\nservice S { rpc A (E) returns (M); })}, ["a.proto"])
    end
  end

  it "reports parse errors with the file system path" do
    dir = proto_tree({"bad.proto" => %(syntax = "proto3";\nmessage {)})
    error = expect_raises(Compiler::ParseError) { Compiler::Importer.new([dir]).code_generator_request(["bad.proto"]) }
    error.filename.should eq(File.join(dir, "bad.proto"))
    error.message.should eq("#{File.join(dir, "bad.proto")}:2:9: Expected identifier, found \"{\".")
  end

  describe "options" do
    custom = <<-PROTO
      syntax = "proto2";
      package c;
      import "google/protobuf/descriptor.proto";
      message Rule { optional string get = 1; repeated int32 codes = 2; optional Rule nested = 3; }
      enum Level { LOW = 0; HIGH = 1; }
      extend google.protobuf.FileOptions {
        optional string note = 50000;
        repeated int32 numbers = 50001;
        optional Rule rule = 50002;
        optional string hidden = 50003 [retention = RETENTION_SOURCE];
      }
      extend google.protobuf.FieldOptions {
        optional Level level = 50000;
        optional uint32 limit = 50001;
        optional bool flag = 50002;
      }
      PROTO

    it "interprets custom options into unknown fields in canonical order" do
      request = link({"custom.proto" => custom, "main.proto" => <<-PROTO}, ["main.proto"])
        syntax = "proto3";
        import "custom.proto";
        option (c.rule).get = "/a";
        option (c.numbers) = 2;
        option (c.note) = "n";
        option (c.numbers) = 1;
        option (c.rule).codes = 5;
        option (c.hidden) = "dropped";
        message M { int32 a = 1 [(c.level) = HIGH, (c.limit) = 4294967295, (c.flag) = true]; }
        PROTO
      main = request.proto_file.last
      options = main.options.not_nil!
      options.uninterpreted_option.should be_empty
      # note (50000), numbers (50001) in order, rule (50002) merged.
      options.unknown_fields.should eq(hexbytes("82b51801 6e 88b51802 88b51801 92b51806 0a022f61 1005"))
      main.message_type[0].field[0].options.not_nil!.unknown_fields.should eq(hexbytes("80b51801 88b518ffffffff0f 90b51801"))
    end

    it "encodes aggregate option values" do
      request = link({"custom.proto" => custom, "main.proto" => <<-PROTO}, ["main.proto"])
        syntax = "proto3";
        import "custom.proto";
        option (c.rule) = { nested { get: "x" } codes: [3, 1] get: "/b" codes: 2 };
        PROTO
      request.proto_file.last.options.not_nil!.unknown_fields.should eq(hexbytes("92b5180f 0a022f62 1003 1001 1002 1a03 0a0178"))
    end

    it "reports option errors" do
      {
        %(option (c.nope) = 1;)                           => %(Option "(c.nope)" unknown.),
        %(option nope = 1;)                               => %(Option "nope" unknown.),
        %(option (c.note) = 1;)                           => %(Value must be quoted string for string option "(c.note)".),
        %(option (c.note) = "a";\noption (c.note) = "b";) => %(Option "(c.note)" was already set.),
        %(option (c.rule) = "x";)                         => %(Option "(c.rule)" is a message.),
        %(option (c.rule) = { nope: 1 };)                 => %(has no field named "nope"),
        %(option (c.rule).get.x = 1;)                     => %(is an atomic type, not a message),
        %(option java_package = 1;)                       => %(Value must be quoted string),
        %(option optimize_for = FAST;)                    => %(has no value named "FAST"),
        %(option cc_enable_arenas = 1;)                   => %(Value must be "true" or "false"),
        %(message M { int32 a = 1 [(c.limit) = -1]; })    => %(Value must be non-negative integer),
        %(message M { int32 a = 1 [(c.level) = 1]; })     => %(Value must be identifier),
        %(message M { int32 a = 1 [(c.note) = "x"]; })    => %(is not a field or extension of message "FieldOptions"),
      }.each do |source, message|
        error = expect_raises(Compiler::ParseError) do
          link({"custom.proto" => custom, "main.proto" => %(syntax = "proto3";\nimport "custom.proto";\npackage p;\n#{source}\n)}, ["main.proto"])
        end
        error.description.should contain(message)
        error.line.should be >= 4
      end
    end

    it "normalizes default values like protoc" do
      request = link({"main.proto" => <<-'PROTO'}, ["main.proto"])
        syntax = "proto2";
        enum E { A = 1; B = 2; }
        message M {
          optional int32 a = 1 [default = 0x10];
          optional float b = 2 [default = 1e10];
          optional double c = 3 [default = 0.1];
          optional bytes d = 4 [default = "\001\377\n"];
          optional E e = 5 [default = B];
          optional double f = 6 [default = -inf];
          optional uint64 g = 7 [default = 0777];
        }
        PROTO
      request.proto_file.last.message_type[0].field.map(&.default_value).should eq(["16", "1e+10", "0.1", "\\001\\377\\n", "B", "-inf", "511"])
    end

    it "rejects invalid default values" do
      {
        %(optional int32 a = 1 [default = 2147483648];) => "Integer out of range.",
        %(optional uint32 a = 1 [default = -1];)        => "Unsigned field can't have negative default value.",
        %(optional bool a = 1 [default = 1];)           => "Boolean default must be true or false.",
        %(optional E a = 1 [default = C];)              => %(Enum type "E" has no value named "C".),
        %(repeated int32 a = 1 [default = 1];)          => "Repeated fields can't have default values.",
        %(optional M a = 1 [default = 1];)              => "Messages can't have default values.",
        %(optional double a = 1 [default = x];)         => %(Couldn't parse default value "x".),
      }.each do |field, message|
        error = expect_raises(Compiler::ParseError) do
          link({"main.proto" => %(syntax = "proto2";\nenum E { A = 1; }\nmessage M {\n  #{field}\n}\n)}, ["main.proto"])
        end
        error.description.should eq(message)
        error.line.should eq(4)
      end
    end
  end
end
