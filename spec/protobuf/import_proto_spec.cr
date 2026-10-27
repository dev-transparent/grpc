require "./protobuf_helper"

# Compiled into the spec binary by the macro: no protoc involved.
Protobuf.import_proto "proto/parser_test/proto3.proto"
Protobuf.import_proto "proto/parser_test/torture.proto", "proto"
# Already defined through torture.proto's public import chain; the guard
# must keep it from being defined twice.
Protobuf.import_proto "proto/parser_test/nested/deep.proto", "proto"

private def compile(source : String) : {Bool, String}
  dir = File.join(ProtobufSpec::ROOT, "tmp", "import_proto_spec")
  Dir.mkdir_p(dir)
  path = File.join(dir, "#{Process.pid}_#{Random.new.hex(4)}.cr")
  File.write(path, source)
  output = IO::Memory.new
  status = Process.run("crystal", ["build", "--no-codegen", "--no-color", path], output: output, error: output, chdir: ProtobufSpec::ROOT)
  {status.success?, output.to_s}
ensure
  File.delete?(path) if path
end

describe "Protobuf.import_proto" do
  it "defines messages, enums and nested types from a proto3 file" do
    message = Torture::P3::Msg.new(opt: 1, plain: 2, nums: [-1_i64, 2_i64], e: Torture::P3::Msg::E::E_ONE, a: 7)
    decoded = Torture::P3::Msg.from_protobuf(message.to_protobuf)
    decoded.should eq(message)
    decoded.kind_case.should eq(:a)
    decoded.opt.should eq(1)
    Torture::P3::Msg.new.opt.should be_nil
  end

  it "uses bundled well-known types for google/protobuf imports" do
    message = Torture::P3::Msg.new(wrapped: Google::Protobuf::StringValue.new(value: "w"),
      anys: {"k" => Google::Protobuf::Any.new(type_url: "t", value: Bytes[1])})
    Torture::P3::Msg.from_protobuf(message.to_protobuf).should eq(message)
  end

  it "defines imported files (including public import chains) once" do
    outer = Torture::V1::Outer.new(req: 1_i64, dep: [Torture::V1::Dep.new(x: 3)], re: Torture::V1::Reexported.new(y: "y"),
      inners: {"a" => Torture::V1::Outer::Inner.new(value: 2)}, name: "n")
    Torture::V1::Outer.from_protobuf(outer.to_protobuf).should eq(outer)
    {{ Protobuf::ImportedFiles.constants.map(&.stringify).select(&.includes?("deep")).size }}.should eq(1)
  end

  it "decodes proto2 groups like the plugin output" do
    bytes = hexbytes("f3 01 0a 01 61 f4 01") # Result group (field 30) with url = "a"
    message = Torture::V1::Outer.from_protobuf(bytes)
    message.result.should eq([Torture::V1::Outer::Result.new(url: "a")])
    message.to_protobuf.should eq(bytes)
  end

  it "registers imported files with descriptors identical to protoc's" do
    descriptor = Protobuf::Registry.file_descriptor("parser_test/torture.proto").not_nil!
    descriptor.package.should eq("torture.v1")
    Torture::V1::Outer.full_name.should eq("torture.v1.Outer")
    Torture::V1::Outer.descriptor.name.should eq("Outer")
    Protobuf::Registry.message_class("torture.v1.Outer").should eq(Torture::V1::Outer)
  end

  it "reports .proto errors at the macro call site" do
    proto = File.join(ProtobufSpec::ROOT, "tmp", "import_proto_spec", "broken.proto")
    Dir.mkdir_p(File.dirname(proto))
    File.write(proto, %(syntax = "proto3";\nmessage M {\n  Missing m = 1;\n}\n))
    ok, output = compile(%(require "../../src/protobuf"\n\nProtobuf.import_proto "broken.proto"\n))
    ok.should be_false
    output.should contain(%(Protobuf.import_proto "broken.proto"))
    output.should contain(%(#{proto}:3:3: "Missing" is not defined.))
  end

  it "rejects non-literal paths" do
    ok, output = compile(%(require "../../src/protobuf"\nPATH = "x.proto"\nProtobuf.import_proto PATH\n))
    ok.should be_false
    output.should contain("Protobuf.import_proto expects a string literal path")
  end

  it "prints the generated code with dump: true" do
    ok, output = compile(%(require "../../src/protobuf"\nProtobuf.import_proto "../../examples/helloworld/proto/helloworld.proto", dump: true\n))
    ok.should be_true
    output.should contain("class HelloRequest")
    output.should contain("{% unless ::Protobuf::ImportedFiles.has_constant?")
    # Protobuf.import_proto only generates messages.
    output.should_not contain("::GRPC::Service")
  end
end
