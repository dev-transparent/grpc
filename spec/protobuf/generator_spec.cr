require "./protobuf_helper"
require "file_utils"

private alias Generator = Protobuf::Compiler::Generator
private alias D = Google::Protobuf
private alias CodeGeneratorRequest = Google::Protobuf::Compiler::CodeGeneratorRequest
private alias CodeGeneratorResponse = Google::Protobuf::Compiler::CodeGeneratorResponse

private def generated(protos : Array(String), parameter : String? = nil) : Hash(String, String)
  response = ProtobufSpec.generate(protos, parameter)
  response.error.should be_nil
  ProtobufSpec.files(response)
end

# Builds a request from hand-written descriptors.
private def request(files : Array(D::FileDescriptorProto), generate : Array(String), parameter : String? = nil) : CodeGeneratorRequest
  CodeGeneratorRequest.new(file_to_generate: generate, parameter: parameter, proto_file: files)
end

private def message_descriptor(name : String, fields = [] of D::FieldDescriptorProto) : D::DescriptorProto
  D::DescriptorProto.new(name: name, field: fields)
end

private def message_field(name : String, number : Int32, type_name : String) : D::FieldDescriptorProto
  D::FieldDescriptorProto.new(name: name, number: number, label: D::FieldDescriptorProto::Label::LABEL_OPTIONAL,
    type: D::FieldDescriptorProto::Type::TYPE_MESSAGE, type_name: type_name)
end

private def proto_file(name : String, package : String, messages = [] of D::DescriptorProto, dependency = [] of String) : D::FileDescriptorProto
  D::FileDescriptorProto.new(name: name, package: package, syntax: "proto3", message_type: messages, dependency: dependency)
end

describe Protobuf::Compiler::Generator do
  describe "naming" do
    it "converts packages to module names" do
      Generator.module_name("foo").should eq("Foo")
      Generator.module_name("foo.bar_baz").should eq("Foo::BarBaz")
      Generator.module_name("google.protobuf").should eq("Google::Protobuf")
      Generator.module_name("my_pkg.v1beta1").should eq("MyPkg::V1beta1")
    end

    it "converts identifiers to constant names" do
      Generator.constant_name("foo").should eq("Foo")
      Generator.constant_name("foo_bar").should eq("FooBar")
      Generator.constant_name("fooBar").should eq("FooBar")
      Generator.constant_name("FooBar").should eq("FooBar")
      Generator.constant_name("_foo").should eq("Foo")
      Generator.constant_name("foo__bar").should eq("Foo_Bar")
      Generator.constant_name("http2_frame").should eq("Http2Frame")
      Generator.constant_name("1abc").should eq("X1abc")
    end

    it "converts identifiers to method names" do
      Generator.method_name("FooBar").should eq("foo_bar")
      Generator.method_name("fooBar").should eq("foo_bar")
      Generator.method_name("HTTPServer").should eq("http_server")
      Generator.method_name("getHTTPResponse").should eq("get_http_response")
      Generator.method_name("Foo2Bar").should eq("foo2_bar")
      Generator.method_name("field0name5").should eq("field0name5")
      Generator.method_name("already_snake").should eq("already_snake")
      Generator.method_name("2fa").should eq("_2fa")
    end

    it "escapes field names that clash with keywords or reserved methods" do
      %w(end class def self nil true begin yield require).each do |name|
        Generator.field_name(name).should eq("#{name}_")
      end
      %w(hash clone dup to_s inspect object_id to_protobuf from_protobuf merge_from unknown_fields initialize new).each do |name|
        Generator.field_name(name).should eq("#{name}_")
      end
      Generator.field_name("name").should eq("name")
      Generator.field_name("type").should eq("type")
      Generator.field_name("End").should eq("end_")
    end

    it "escapes RPC method names that clash with client and service methods" do
      Generator.rpc_method_name("SayHello").should eq("say_hello")
      Generator.rpc_method_name("UnaryCall").should eq("unary_call")
      Generator.rpc_method_name("Close").should eq("close_")
      Generator.rpc_method_name("Channel").should eq("channel_")
      Generator.rpc_method_name("Metadata").should eq("metadata_")
      Generator.rpc_method_name("ServiceName").should eq("service_name_")
      Generator.rpc_method_name("End").should eq("end_")
      Generator.rpc_method_name("Hash").should eq("hash_")
    end

    it "converts enum value names to member names" do
      Generator.enum_member_name("FOO_BAR").should eq("FOO_BAR")
      Generator.enum_member_name("foo").should eq("Foo")
      Generator.enum_member_name("_FOO").should eq("X_FOO")
    end
  end

  describe "parameters and responses" do
    it "reports supported features and editions" do
      response = Generator.call(request([proto_file("a.proto", "a")], ["a.proto"]))
      response.error.should be_nil
      features = response.supported_features.not_nil!
      (features & CodeGeneratorResponse::Feature::FEATURE_PROTO3_OPTIONAL.value).should_not eq(0)
      (features & CodeGeneratorResponse::Feature::FEATURE_SUPPORTS_EDITIONS.value).should_not eq(0)
      response.minimum_edition.should eq(D::Edition::EDITION_PROTO2.value)
      response.maximum_edition.should eq(D::Edition::EDITION_2026.value)
    end

    it "accepts edition UNSTABLE with experimental_editions=true" do
      response = Generator.call(request([proto_file("a.proto", "a")], ["a.proto"], "experimental_editions=true"))
      response.maximum_edition.should eq(D::Edition::EDITION_UNSTABLE.value)
    end

    it "names output files after the proto file" do
      response = Generator.call(request([proto_file("foo/bar.proto", "foo")], ["foo/bar.proto"]))
      response.file.map(&.name).should eq(["foo/bar.pb.cr"])
    end

    it "emits a gRPC file for services unless grpc=false" do
      service = D::ServiceDescriptorProto.new(name: "Svc", method: [
        D::MethodDescriptorProto.new(name: "Call", input_type: ".foo.M", output_type: ".foo.M"),
      ])
      file = proto_file("foo/bar.proto", "foo", [message_descriptor("M")])
      file.service = [service]
      Generator.call(request([file], ["foo/bar.proto"])).file.map(&.name).should eq(["foo/bar.pb.cr", "foo/bar_grpc.pb.cr"])
      Generator.call(request([file], ["foo/bar.proto"], "grpc=false")).file.map(&.name).should eq(["foo/bar.pb.cr"])
      Generator.call(request([file], ["foo/bar.proto"], "grpc=true")).file.size.should eq(2)
    end

    it "adds requires given as parameters" do
      response = Generator.call(request([proto_file("a.proto", "a")], ["a.proto"], "require=grpc, require=./support"))
      content = response.file.first.content.not_nil!
      content.should contain(%(require "grpc"\nrequire "./support"\n))
    end

    it "reports unknown parameters as an error" do
      response = Generator.call(request([proto_file("a.proto", "a")], ["a.proto"], "grpc=false,bogus=1"))
      response.error.should eq(%(Unknown parameter "bogus"))
      response.file.should be_empty
    end

    it "reports unknown files and types as errors" do
      Generator.call(request([proto_file("a.proto", "a")], ["b.proto"])).error.not_nil!.should contain("b.proto not found")
      file = proto_file("a.proto", "a", [message_descriptor("M", [message_field("x", 1, ".a.Missing")])])
      Generator.call(request([file], ["a.proto"])).error.not_nil!.should contain("Unknown type .a.Missing")
    end

    it "only generates the requested files" do
      dep = proto_file("dep.proto", "dep", [message_descriptor("D")])
      main = proto_file("main.proto", "main", [message_descriptor("M", [message_field("d", 1, ".dep.D")])], ["dep.proto"])
      response = Generator.call(request([dep, main], ["main.proto"]))
      response.file.map(&.name).should eq(["main.pb.cr"])
      response.file.first.content.not_nil!.should contain("field d : ::Dep::D, 1")
    end
  end

  describe "requires" do
    it "uses relative requires between files in different directories" do
      y = proto_file("c/y.proto", "y", [message_descriptor("Y")])
      z = proto_file("a/b/sub/z.proto", "z", [message_descriptor("Z")])
      w = proto_file("w.proto", "w", [message_descriptor("W")])
      x = proto_file("a/b/x.proto", "x", [message_descriptor("X", [
        message_field("y", 1, ".y.Y"), message_field("z", 2, ".z.Z"), message_field("w", 3, ".w.W"),
      ])], ["c/y.proto", "a/b/sub/z.proto", "w.proto"])
      top = proto_file("top.proto", "top", [message_descriptor("T", [message_field("x", 1, ".x.X")])], ["a/b/x.proto"])
      files = ProtobufSpec.files(Generator.call(request([y, z, w, x, top], ["a/b/x.proto", "top.proto"])))
      files["a/b/x.pb.cr"].should contain(%(require "../../c/y.pb"\nrequire "./sub/z.pb"\nrequire "../../w.pb"\n))
      files["top.pb.cr"].should contain(%(require "./a/b/x.pb"\n))
    end

    it "does not require well-known types (they are part of the runtime)" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should_not contain("require")
      content.should contain("field created_at : ::Google::Protobuf::Timestamp, 4")
    end

    it "requires dependencies relative to the importing file" do
      skip_without_protoc
      content = generated(["spec_test/sub/imported.proto"])["spec_test/sub/imported.pb.cr"]
      content.should contain(%(require "../types.pb"))
      content.should contain("map outers : Hash(String, ::SpecTest::Outer), 3")
    end
  end

  describe "generated code" do
    it "emits nested messages and enums with fully qualified references" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should contain(<<-CRYSTAL)
          # Nested types and recursion.
          @[::Protobuf::TypeName("spec_test.Outer")]
          class Outer
            include ::Protobuf::Message

            @[::Protobuf::TypeName("spec_test.Outer.Kind")]
            enum Kind : Int32
              KIND_UNSPECIFIED = 0
              KIND_A = 1
            end

            @[::Protobuf::TypeName("spec_test.Outer.Middle")]
            class Middle
              include ::Protobuf::Message

              @[::Protobuf::TypeName("spec_test.Outer.Middle.Inner")]
              class Inner
                include ::Protobuf::Message

                field text : String, 1
                field kind : ::SpecTest::Outer::Kind, 2
              end

              field inner : ::SpecTest::Outer::Middle::Inner, 1
              repeated inners : ::SpecTest::Outer::Middle::Inner, 2
            end

            field middle : ::SpecTest::Outer::Middle, 1
            field child : ::SpecTest::Outer, 2
            field kind : ::SpecTest::Outer::Kind, 3
            field created_at : ::Google::Protobuf::Timestamp, 4
            repeated inners : ::SpecTest::Outer::Middle::Inner, 5
          end
        CRYSTAL
    end

    it "detects map entries and does not emit entry classes" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should_not contain("class Int32ToStringEntry")
      content.should_not contain("Entry,\n")
      content.should contain("map int32_to_string : Hash(Int32, String), 1\n")
      content.should contain("map sint32_to_sint32 : Hash(Int32, Int32), 5, key_type: :sint32, value_type: :sint32\n")
      content.should contain("map sfixed64_to_sfixed64 : Hash(Int64, Int64), 10, key_type: :sfixed64, value_type: :sfixed64\n")
      content.should contain("map string_to_message : Hash(String, ::SpecTest::Scalars), 13\n")
      content.should contain("map string_to_color : Hash(String, ::SpecTest::Color), 14\n")
    end

    it "does not treat a message named *Entry as a map without the map_entry option" do
      entry = message_descriptor("ThingEntry", [
        D::FieldDescriptorProto.new(name: "key", number: 1, label: D::FieldDescriptorProto::Label::LABEL_OPTIONAL, type: D::FieldDescriptorProto::Type::TYPE_STRING),
        D::FieldDescriptorProto.new(name: "value", number: 2, label: D::FieldDescriptorProto::Label::LABEL_OPTIONAL, type: D::FieldDescriptorProto::Type::TYPE_STRING),
      ])
      field = D::FieldDescriptorProto.new(name: "things", number: 1, label: D::FieldDescriptorProto::Label::LABEL_REPEATED,
        type: D::FieldDescriptorProto::Type::TYPE_MESSAGE, type_name: ".a.M.ThingEntry")
      message = D::DescriptorProto.new(name: "M", field: [field], nested_type: [entry])
      content = Generator.call(request([proto_file("a.proto", "a", [message])], ["a.proto"])).file.first.content.not_nil!
      content.should contain("class ThingEntry")
      content.should contain("repeated things : ::A::M::ThingEntry, 1")
    end

    it "emits proto3 optional fields with presence and without synthetic oneofs" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should contain("field int32_value : Int32, 1, optional: true\n")
      content.should contain("field color : ::SpecTest::Color, 3, optional: true\n")
      content.should contain("field message_value : ::SpecTest::Scalars, 5\n")
      content.should_not contain("oneof _")
    end

    it "emits oneofs with comments" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should contain(<<-CRYSTAL)
            field other : Int32, 6

            # The choice.
            oneof value do
              field name : String, 1
              field number : Int32, 2
              field message : ::SpecTest::Scalars, 3
              field color : ::SpecTest::Color, 4
              field data : Bytes, 5
            end
        CRYSTAL
    end

    it "emits type overrides, packed and utf8 options for proto3" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should contain("field sint32_value : Int32, 5, type: :sint32\n")
      content.should contain("field sfixed64_value : Int64, 10, type: :sfixed64\n")
      content.should contain("field bytes_value : Bytes, 15\n")
      content.should contain("repeated int32_values : Int32, 1\n")
      content.should contain("repeated unpacked_int32_values : Int32, 10, packed: false\n")
      content.should contain("repeated strings : String, 7\n")
      content.should_not contain("utf8: false")
    end

    it "uses proto2 presence, packing and UTF-8 rules" do
      skip_without_protoc
      content = generated(["spec_test/proto2.proto"])["spec_test/proto2.pb.cr"]
      content.should contain("field value : Int32, 1, optional: true\n")
      content.should contain("field name : String, 2, required: true, utf8: false\n")
      content.should contain("repeated values : Int32, 3, packed: false\n")
      content.should contain("repeated packed_values : Int32, 4\n")
      content.should contain("field settings : ::SpecTest::Proto2::Legacy::Settings, 6, type: :group\n")
      content.should contain("field with_default : Int32, 8, optional: true, default: 42\n")
      content.should contain("class Settings")
    end

    it "uses editions features for presence, packing and UTF-8" do
      skip_without_protoc
      files = generated(["spec_test/editions.proto", "spec_test/editions_implicit.proto"])
      editions = files["spec_test/editions.pb.cr"]
      editions.should contain("field explicit_value : Int32, 1, optional: true\n")
      editions.should contain("field implicit_value : Int32, 2\n")
      editions.should contain("field required_value : Int32, 3, required: true\n")
      editions.should contain("repeated packed_values : Int32, 4\n")
      editions.should contain("repeated expanded_values : Int32, 5, packed: false\n")
      editions.should contain("field checked_text : String, 6, optional: true\n")
      editions.should contain("field unchecked_text : String, 7, optional: true, utf8: false\n")
      editions.should contain("repeated unchecked_texts : String, 8, utf8: false\n")
      editions.should contain("field delimited_child : ::SpecTest::Editions::EditionsMessage::Child, 10, type: :group\n")

      implicit = files["spec_test/editions_implicit.pb.cr"]
      implicit.should contain("field value : Int32, 1\n")
      implicit.should contain("repeated values : Int32, 2, packed: false\n")
      implicit.should contain("field text : String, 3, utf8: false\n")
      implicit.should contain("map labels : Hash(String, String), 4, utf8: false\n")
      implicit.should contain("field explicit_value : Int32, 5, optional: true\n")
      implicit.should contain("repeated packed_values : Int32, 6\n")
      implicit.should contain("field checked_text : String, 7\n")
    end

    it "emits extensions as constants, avoiding clashes with types" do
      skip_without_protoc
      dir = ProtobufSpec.tmp_path("ext")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "e.proto"), <<-PROTO)
        syntax = "proto2";
        package x;
        message FOO { extensions 1 to 10; extend FOO { optional int32 bar = 1; } message BAR {} }
        extend FOO { optional sint64 foo = 2; repeated int32 nums = 3 [packed = true]; optional string s = 4; }
        PROTO
      content = ProtobufSpec.files(ProtobufSpec.generate(["e.proto"], nil, ["-I#{dir}"]))["e.pb.cr"]
      content.should contain(%(    BAR_EXTENSION = ::Protobuf::Extension(::X::FOO, Int32).new("x.FOO.bar", 1)\n))
      content.should contain(%(  FOO_EXTENSION = ::Protobuf::Extension(::X::FOO, Int64).new("x.foo", 2, type: :sint64)\n))
      content.should contain(%(  NUMS = ::Protobuf::Extension(::X::FOO, ::Array(Int32)).new("x.nums", 3, packed: true)\n))
      content.should contain(%(  S = ::Protobuf::Extension(::X::FOO, String).new("x.s", 4, utf8: false)\n))
      content.should contain("    ::X::FOO::BAR_EXTENSION,\n    ::X::FOO_EXTENSION,\n    ::X::NUMS,\n    ::X::S,\n  ] of ::Protobuf::ExtensionField,")
    end

    it "emits annotations for proto names, closed enums, renamed enum values and MessageSets" do
      skip_without_protoc
      dir = ProtobufSpec.tmp_path("ann")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "a.proto"), <<-PROTO)
        syntax = "proto2";
        package a.b;
        enum E { lower = 1; _under = 2; UPPER = 3; }
        message S { option message_set_wire_format = true; extensions 4 to max; }
        PROTO
      content = ProtobufSpec.files(ProtobufSpec.generate(["a.proto"], nil, ["-I#{dir}"]))["a.pb.cr"]
      content.should contain(%(    @[::Protobuf::TypeName("a.b.E")]\n    @[::Protobuf::ClosedEnum]\n    @[::Protobuf::EnumValueNames({"Lower" => "lower", "X_under" => "_under"})]\n    enum E : Int32\n))
      content.should contain(%(    @[::Protobuf::TypeName("a.b.S")]\n    @[::Protobuf::MessageSet]\n    class S\n))
    end

    it "embeds the descriptor without source info and registers the file" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should contain("::Protobuf::Registry.register_file(\n  \"spec_test/types.proto\",\n  \"\\x0A\\x15spec_test/types.proto")
      content.should contain("    ::SpecTest::Outer::Middle::Inner,\n")
      Generator.bytes_literal(Bytes[0, 0x22, 0x23, 0x5c, 0x41, 0x7f]).should eq([%("\\x00\\x22\\x23\\x5CA\\x7F")])
      Generator.bytes_literal(Bytes.empty).should eq([%("")])
      Generator.bytes_literal(Bytes.new(10, 0x41_u8), width: 4).should eq([%("AAAA"), %("AAAA"), %("AA")])
    end

    it "fully qualifies scalar types shadowed by types of enclosing packages" do
      string_field = D::FieldDescriptorProto.new(name: "text", number: 1,
        label: D::FieldDescriptorProto::Label::LABEL_OPTIONAL, type: D::FieldDescriptorProto::Type::TYPE_STRING)
      int_field = D::FieldDescriptorProto.new(name: "count", number: 2,
        label: D::FieldDescriptorProto::Label::LABEL_OPTIONAL, type: D::FieldDescriptorProto::Type::TYPE_INT32)
      parent = proto_file("a/string.proto", "a", [message_descriptor("String")])
      child = proto_file("a/b/m.proto", "a.b", [message_descriptor("M", [string_field, int_field])], ["a/string.proto"])
      unrelated = proto_file("c/m.proto", "c", [message_descriptor("N", [string_field])])
      files = ProtobufSpec.files(Generator.call(request([parent, child, unrelated], ["a/b/m.proto", "c/m.proto"])))
      files["a/b/m.pb.cr"].should contain("field text : ::String, 1\n")
      files["a/b/m.pb.cr"].should contain("field count : Int32, 2\n")
      files["c/m.pb.cr"].should contain("field text : String, 1\n")
    end

    it "escapes keyword field names" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should contain("field end_ : Int32, 1, proto_name: \"end\"\n")
      content.should contain("field class_ : String, 2, proto_name: \"class\"\n")
      content.should contain("field hash_ : Bool, 3, proto_name: \"hash\"\n")
      content.should contain("field self_ : Int32, 6, proto_name: \"self\"\n")
    end

    it "fully qualifies scalar types shadowed by generated types" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should contain("      field value : ::String, 1\n")
      content.should contain("    field flag : ::Bool, 1\n")
      content.should contain("    field text : ::String, 2\n")
      content.should contain("    map flags : Hash(::String, ::Bool), 5\n")
      # Unaffected messages keep the short names.
      content.should contain("    field bool_value : Bool, 13\n")
    end

    it "carries comments into the output" do
      skip_without_protoc
      content = generated(["spec_test/types.proto"])["spec_test/types.pb.cr"]
      content.should start_with("# Code generated by protoc-gen-crystal. DO NOT EDIT.\n# source: spec_test/types.proto\n")
      content.should contain("  # A colour.\n  @[::Protobuf::TypeName(\"spec_test.Color\")]\n  enum Color : Int32\n    # Unset.\n    COLOR_UNSPECIFIED = 0\n")
      content.should contain("    # Negative values are encoded as 10-byte varints.\n    NEGATIVE = -1\n")
      content.should contain("  # Every scalar type, with implicit presence.\n  @[::Protobuf::TypeName(\"spec_test.Scalars\")]\n  class Scalars\n")
    end

    it "generates gRPC service files" do
      skip_without_protoc
      files = generated(["spec_test/service.proto"])
      files.keys.sort.should eq(["spec_test/service.pb.cr", "spec_test/service_grpc.pb.cr"])
      files["spec_test/service.pb.cr"].should contain(%(require "./types.pb"))
      grpc = files["spec_test/service_grpc.pb.cr"]
      grpc.should contain(%(require "./service.pb"))
      grpc.should contain("    # Echoes things.\n    module Echo\n")
      grpc.should contain(%(SERVICE_NAME = "spec_test.service.Echo"))
      grpc.should contain("        # Unary.\n        # Returns a `::SpecTest::Scalars`.\n        abstract def echo(request : ::SpecTest::Scalars, context : ::GRPC::ServerContext)")
      grpc.should contain("abstract def server_stream(request : ::SpecTest::Scalars, responses : ::GRPC::ResponseStream(::SpecTest::Scalars), context : ::GRPC::ServerContext)")
      grpc.should contain("abstract def client_stream(requests : ::GRPC::RequestStream(::SpecTest::Scalars), context : ::GRPC::ServerContext)")
      grpc.should contain("abstract def bidi(requests : ::GRPC::RequestStream(::SpecTest::Scalars), responses : ::GRPC::ResponseStream(::SpecTest::Scalars), context : ::GRPC::ServerContext)")
      grpc.should contain("abstract def close_(request : ::SpecTest::Empty, context : ::GRPC::ServerContext)")
      grpc.should contain(%(::GRPC::RpcMethod.unary("Close", ::SpecTest::Empty, ::SpecTest::Empty) { |request, context| close_(request, context) },))
      grpc.should contain(%(call_unary("/spec_test.service.Echo/Echo", request, ::SpecTest::Scalars, metadata, deadline, options)))
      grpc.should contain(%(call_bidi_streaming("/spec_test.service.Echo/Bidi", ::SpecTest::Scalars, ::SpecTest::Scalars, metadata, deadline, options)))
      grpc.should contain("def close__call(request : ::SpecTest::Empty")
    end

    it "only emits service files when grpc is enabled" do
      skip_without_protoc
      generated(["spec_test/service.proto"], "grpc=false").keys.should eq(["spec_test/service.pb.cr"])
    end
  end

  describe "checked-in output" do
    it "matches the generated spec protos (script/generate_spec_protos.sh)" do
      skip_without_protoc
      files = generated(ProtobufSpec::SPEC_PROTOS, "grpc=false,experimental_editions=true")
      files.keys.sort.should eq(ProtobufSpec::SPEC_PROTOS.map(&.rchop(".proto").+(".pb.cr")).sort)
      files.each do |name, content|
        File.read(File.join(__DIR__, "generated", name)).should eq(content)
      end
    end

    it "reproduces the bundled well-known types and descriptors (self-hosting fixpoint)" do
      skip_without_protoc
      include_dir = ProtobufSpec.protoc_include.not_nil!
      response = ProtobufSpec.generate(ProtobufSpec::WELL_KNOWN_PROTOS, nil, ["-I#{include_dir}"])
      response.error.should be_nil
      files = ProtobufSpec.files(response)
      files.size.should eq(ProtobufSpec::WELL_KNOWN_PROTOS.size)
      files.each do |name, content|
        File.read(File.join(ProtobufSpec::ROOT, "src", "protobuf", name)).should eq(content)
      end
    end
  end

  describe "protoc-gen-crystal plugin" do
    plugin = File.join(ProtobufSpec::TMP_DIR, "protoc-gen-crystal")
    built = false

    build = -> do
      unless built
        Dir.mkdir_p(ProtobufSpec::TMP_DIR)
        output = IO::Memory.new
        status = Process.run("crystal", ["build", File.join(ProtobufSpec::ROOT, "src", "protoc-gen-crystal.cr"), "-o", plugin],
          output: output, error: output)
        raise "Failed to build plugin: #{output}" unless status.success?
        built = true
      end
    end

    it "generates the same output as the in-process generator" do
      skip_without_protoc
      build.call
      out_dir = ProtobufSpec.tmp_path("plugin-out")
      Dir.mkdir_p(out_dir)
      begin
        status, _, error = ProtobufSpec.run_protoc(["--plugin=protoc-gen-crystal=#{plugin}", "--crystal_out=#{out_dir}"] +
                                                   ProtobufSpec.include_args + ["spec_test/service.proto", "spec_test/sub/imported.proto"])
        error.should eq("")
        status.success?.should be_true
        expected = generated(["spec_test/service.proto", "spec_test/sub/imported.proto"])
        expected.each do |name, content|
          File.read(File.join(out_dir, name)).should eq(content)
        end
      ensure
        FileUtils.rm_rf(out_dir)
      end
    end

    it "reports errors through protoc" do
      skip_without_protoc
      build.call
      out_dir = ProtobufSpec.tmp_path("plugin-err")
      Dir.mkdir_p(out_dir)
      begin
        status, _, error = ProtobufSpec.run_protoc(["--plugin=protoc-gen-crystal=#{plugin}", "--crystal_out=bogus=1:#{out_dir}"] +
                                                   ProtobufSpec.include_args + ["spec_test/types.proto"])
        status.success?.should be_false
        error.should contain(%(Unknown parameter "bogus"))
      ensure
        FileUtils.rm_rf(out_dir)
      end
    end
  end
end
