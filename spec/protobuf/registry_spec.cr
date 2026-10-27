require "./protobuf_helper"

# Also defined by import_proto_spec.cr; the import guard keeps it single.
Protobuf.import_proto "proto/parser_test/proto3.proto"

private alias Registry = Protobuf::Registry
private alias GP = Google::Protobuf

# A hand-written message without a proto name.
module RegistrySpec
  class Plain
    include Protobuf::Message

    field x : Int32, 1
  end
end

describe Protobuf::Registry do
  it "registers the bundled well-known types and descriptor.proto" do
    ProtobufSpec::WELL_KNOWN_PROTOS.each do |name|
      Registry.file_descriptor(name).not_nil!.name.should eq(name)
    end
    Registry.message_class("google.protobuf.Duration").should eq(GP::Duration)
    Registry.message_class("google.protobuf.FileDescriptorProto").should eq(GP::FileDescriptorProto)
    Registry.message_class("google.protobuf.compiler.CodeGeneratorRequest").should eq(GP::Compiler::CodeGeneratorRequest)
    Registry.message_class?(".google.protobuf.Any").should eq(GP::Any)
    Registry.message_class?("google.protobuf.Nope").should be_nil
    expect_raises(Protobuf::Error, /Unknown message type/) { Registry.message_class("no.Such") }
  end

  it "embeds descriptors identical to protoc's (without source info)" do
    skip_without_protoc
    set = ProtobufSpec.descriptor_set(ProtobufSpec::SPEC_PROTOS)
    ProtobufSpec::SPEC_PROTOS.each do |name|
      expected = set.file.find { |file| file.name == name }.not_nil!.clone
      expected.source_code_info = nil
      Registry.file_descriptor_bytes(name).should eq(expected.to_protobuf)
    end
  end

  it "registers every generated message class, but not map entries" do
    Registry.message_class("spec_test.Outer.Middle.Inner").should eq(SpecTest::Outer::Middle::Inner)
    Registry.message_class("protobuf_test_messages.proto2.TestAllTypesProto2.Data").should eq(ProtobufTestMessages::Proto2::TestAllTypesProto2::Data)
    Registry.message_class?("spec_test.Maps.Int32ToStringEntry").should be_nil
    Registry.message_names.should contain("spec_test.Scalars")
  end

  it "gives message classes their name and descriptors" do
    SpecTest::Outer::Middle.full_name.should eq("spec_test.Outer.Middle")
    SpecTest::Outer::Middle.descriptor.name.should eq("Middle")
    SpecTest::Outer::Middle.descriptor.field.map(&.name).should eq(["inner", "inners"])
    SpecTest::Outer.file_descriptor.name.should eq("spec_test/types.proto")
    GP::Timestamp.descriptor.field.map(&.name).should eq(["seconds", "nanos"])
  end

  it "uses the Crystal name for hand-written messages, which have no descriptor" do
    RegistrySpec::Plain.full_name.should eq("RegistrySpec.Plain")
    expect_raises(Protobuf::Error, /not registered/) { RegistrySpec::Plain.descriptor }
  end

  it "creates, parses and prints messages through message classes" do
    klass = Registry.message_class("spec_test.Scalars")
    message = klass.from_protobuf(hexbytes("0805"))
    message.should eq(SpecTest::Scalars.new(int32_value: 5))
    klass.new_message.should eq(SpecTest::Scalars.new)
    klass.from_json(%({"int32Value":7})).should eq(SpecTest::Scalars.new(int32_value: 7))
    klass.from_json(%({"nope":1}), ignore_unknown_fields: true).should eq(SpecTest::Scalars.new)
    Registry.message_class_for_type_url("type.googleapis.com/spec_test.Scalars").should eq(SpecTest::Scalars)
    Registry.message_class_for_type_url("spec_test.Scalars").should eq(SpecTest::Scalars)
    Registry.message_class_for_type_url("example.com/").should be_nil
  end

  it "finds files by symbol" do
    {
      "spec_test.Outer"                     => "spec_test/types.proto",
      "spec_test.Outer.Middle.Inner"        => "spec_test/types.proto",
      ".spec_test.Color"                    => "spec_test/types.proto",
      "spec_test.RED"                       => "spec_test/types.proto",
      "spec_test.Outer.Kind"                => "spec_test/types.proto",
      "spec_test.Outer.KIND_A"              => "spec_test/types.proto",
      "spec_test.Scalars.int32_value"       => "spec_test/types.proto",
      "spec_test.Choice.value"              => "spec_test/types.proto",
      "spec_test.service.Echo"              => "spec_test/service.proto",
      "spec_test.service.Echo.ServerStream" => "spec_test/service.proto",
      "spec_test.proto2.required_ext"       => "spec_test/proto2.proto",
      "spec_test.sub.Wrapper"               => "spec_test/sub/imported.proto",
      "google.protobuf.Any"                 => "google/protobuf/any.proto",
    }.each do |symbol, file|
      Registry.file_name_containing_symbol(symbol).should eq(file)
      Registry.file_containing_symbol(symbol).not_nil!.name.should eq(file)
    end
    Registry.file_containing_symbol("spec_test").should be_nil
    Registry.file_containing_symbol("spec_test.Nope").should be_nil
    Registry.symbol("spec_test.service.Echo.Bidi").not_nil!.kind.method?.should be_true
    Registry.symbol("spec_test.Outer").not_nil!.kind.message?.should be_true
  end

  it "lists services and their descriptors" do
    Registry.services.should contain("spec_test.service.Echo")
    service = Registry.service_descriptor("spec_test.service.Echo").not_nil!
    service.method.map(&.name).should eq(%w(Echo ServerStream ClientStream Bidi Close))
    service.method[1].server_streaming.should be_true
  end

  it "returns message and enum descriptors" do
    Registry.message_descriptor("spec_test.Outer.Middle").not_nil!.name.should eq("Middle")
    Registry.enum_descriptor("spec_test.Color").not_nil!.value.map(&.name).first.should eq("COLOR_UNSPECIFIED")
    Registry.message_descriptor("spec_test.Color").should be_nil
  end

  it "returns files with their transitive dependencies" do
    Registry.dependencies("spec_test/service.proto").should eq(["spec_test/types.proto"])
    Registry.file_with_dependencies("spec_test/service.proto").map(&.name)
      .should eq(["spec_test/service.proto", "spec_test/types.proto", "google/protobuf/timestamp.proto"])
    Registry.file_with_dependencies("nope.proto").should be_empty
  end

  it "indexes extensions" do
    names = Registry.extensions_of("spec_test.proto2.Requirements").map(&.full_name)
    names.should eq(%w(spec_test.proto2.required_ext spec_test.proto2.packed_ext spec_test.proto2.closed_ext
      spec_test.proto2.closed_list_ext spec_test.proto2.text_ext spec_test.proto2.groupext))
    Registry.extension_numbers("protobuf_test_messages.proto2.TestAllTypesProto2").should eq([120, 121, 133, 134])
    Registry.extension("spec_test.proto2.Requirements", 104).should be(SpecTest::Proto2::TEXT_EXT)
    Registry.extension("spec_test.proto2.text_ext").should be(SpecTest::Proto2::TEXT_EXT)
    Registry.file_containing_extension("spec_test.proto2.Requirements", 104).not_nil!.name.should eq("spec_test/proto2.proto")
    Registry.file_containing_extension("spec_test.proto2.Requirements", 199).should be_nil
    ext = SpecTest::Proto2::PACKED_EXT
    ext.extendee.should eq("spec_test.proto2.Requirements")
    ext.number.should eq(101)
    ext.kind.should eq(:sint32)
    ext.repeated?.should be_true
    ext.packed?.should be_true
  end

  it "ignores identical registrations and rejects conflicting ones" do
    bytes = Registry.file_descriptor_bytes("spec_test/types.proto").not_nil!
    Registry.register_file("spec_test/types.proto", bytes)
    expect_raises(Protobuf::Error, /Conflicting registrations/) do
      Registry.register_file("spec_test/types.proto", GP::FileDescriptorProto.new(name: "spec_test/types.proto").to_protobuf)
    end
  end

  it "registers files defined with import_proto" do
    # Named relative to its directory, the include path used by the macro.
    Registry.file_descriptor("proto3.proto").not_nil!.package.should eq("torture.p3")
  end
end
