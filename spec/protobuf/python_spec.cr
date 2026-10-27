require "./protobuf_helper"

# Randomized cross-implementation round trip with Python's protobuf package:
# Python builds random, fully populated conformance messages and serializes
# them; Crystal decodes and re-encodes them; Python parses Crystal's bytes and
# checks they equal the originals.
module PythonRoundTrip
  SCRIPT  = File.join(__DIR__, "python", "roundtrip.py")
  WORKDIR = File.join(ProtobufSpec::TMP_DIR, "python")
  GEN_DIR = File.join(WORKDIR, "gen")

  @@prepared : Bool? = nil

  def self.python : String?
    path = ENV["PROTOBUF_SPEC_PYTHON"]? || ProtobufSpec::PYTHON
    File::Info.executable?(path) ? path : nil
  end

  def self.run(args : Array(String)) : {Bool, String}
    output = IO::Memory.new
    status = Process.run(python.not_nil!, args, output: output, error: output)
    {status.success?, output.to_s}
  end

  # Generates the Python code for the conformance protos (once per run).
  # Returns false if the interpreter lacks protobuf/grpc_tools.
  def self.prepare : Bool
    if (prepared = @@prepared).nil?
      @@prepared = prepared = generate
    end
    prepared
  end

  private def self.generate : Bool
    ok, _ = run(["-c", "import google.protobuf, grpc_tools.protoc"])
    return false unless ok
    proto_dir = File.join(WORKDIR, "proto", "conformance")
    Dir.mkdir_p(proto_dir)
    Dir.mkdir_p(GEN_DIR)
    %w(test_messages_proto3.proto test_messages_proto2.proto).each do |name|
      File.copy(File.join(ProtobufSpec::PROTO_DIR, "google", "protobuf", name), File.join(proto_dir, name))
    end
    ok, output = run(["-m", "grpc_tools.protoc", "-I#{File.join(WORKDIR, "proto")}", "--python_out=#{GEN_DIR}",
                      "conformance/test_messages_proto3.proto", "conformance/test_messages_proto2.proto"])
    raise "grpc_tools.protoc failed: #{output}" unless ok
    true
  end

  def self.read_messages(path : String) : Array(Bytes)
    data = File.read(path).to_slice
    messages = [] of Bytes
    pos = 0
    while pos < data.size
      length = IO::ByteFormat::BigEndian.decode(UInt32, data[pos, 4]).to_i
      pos += 4
      messages << data[pos, length]
      pos += length
    end
    messages
  end

  def self.write_messages(path : String, messages : Array(Bytes)) : Nil
    File.open(path, "wb") do |file|
      messages.each do |message|
        file.write_bytes(message.size.to_u32, IO::ByteFormat::BigEndian)
        file.write(message)
      end
    end
  end

  def self.generate_messages(kind : String, seed : Int32, count : Int32, single_entry_maps = false) : String
    path = ProtobufSpec.tmp_path("#{kind}-#{seed}-python.bin")
    args = [SCRIPT, GEN_DIR, "gen", kind, seed.to_s, count.to_s, path]
    args << "single" if single_entry_maps
    ok, output = run(args)
    raise "python generation failed: #{output}" unless ok
    path
  end

  def self.check(kind : String, original : String, crystal : String, command = "check") : String
    ok, output = run([SCRIPT, GEN_DIR, command, kind, original, crystal])
    raise "python #{command} failed: #{output}" unless ok
    output
  end

  def self.generate_json(kind : String, seed : Int32, count : Int32) : String
    path = ProtobufSpec.tmp_path("#{kind}-#{seed}-python-json.bin")
    ok, output = run([SCRIPT, GEN_DIR, "gen-json", kind, seed.to_s, count.to_s, path])
    raise "python generation failed: #{output}" unless ok
    path
  end
end

macro skip_without_python
  unless PythonRoundTrip.python && PythonRoundTrip.prepare
    pending!("Python with protobuf and grpcio-tools is not available")
  end
end

private def python_round_trip(kind : String, type : T.class, seed : Int32, count : Int32) forall T
  original = PythonRoundTrip.generate_messages(kind, seed, count)
  crystal = ProtobufSpec.tmp_path("#{kind}-#{seed}-crystal.bin")
  begin
    inputs = PythonRoundTrip.read_messages(original)
    inputs.size.should eq(count)
    outputs = inputs.map do |bytes|
      message = type.from_protobuf(bytes)
      message.clone.should eq(message) unless bytes.size == 0
      message.to_protobuf
    end
    PythonRoundTrip.write_messages(crystal, outputs)
    PythonRoundTrip.check(kind, original, crystal).should contain("ok #{count}")
    {inputs, outputs}
  ensure
    File.delete?(original)
    File.delete?(crystal)
  end
end

describe "Python protobuf cross-implementation round trip" do
  it "round trips random TestAllTypesProto3 messages" do
    skip_without_python
    [1, 2, 3].each do |seed|
      python_round_trip("proto3", ProtobufTestMessages::Proto3::TestAllTypesProto3, seed, 100)
    end
  end

  it "round trips random TestAllTypesProto2 messages (with groups and extensions)" do
    skip_without_python
    [4, 5].each do |seed|
      python_round_trip("proto2", ProtobufTestMessages::Proto2::TestAllTypesProto2, seed, 100)
    end
  end

  it "preserves Python-encoded messages byte for byte as unknown fields" do
    skip_without_python
    path = PythonRoundTrip.generate_messages("proto3", 6, 50)
    begin
      PythonRoundTrip.read_messages(path).each do |bytes|
        message = ProtobufTestMessages::Proto3::NullHypothesisProto3.from_protobuf(bytes)
        message.to_protobuf.should eq(bytes)
      end
    ensure
      File.delete?(path)
    end
  end

  it "re-encodes Python messages byte for byte when maps have at most one entry" do
    skip_without_python
    path = PythonRoundTrip.generate_messages("proto3", 7, 100, single_entry_maps: true)
    begin
      PythonRoundTrip.read_messages(path).each do |bytes|
        message = ProtobufTestMessages::Proto3::TestAllTypesProto3.from_protobuf(bytes)
        ProtobufSpec.hex(message.to_protobuf).should eq(ProtobufSpec.hex(bytes))
      end
    ensure
      File.delete?(path)
    end
  end

  it "parses Python's JSON and produces JSON Python parses back (proto3)" do
    skip_without_python
    python_json_round_trip("proto3", ProtobufTestMessages::Proto3::TestAllTypesProto3, 8, 100)
  end

  it "parses Python's JSON and produces JSON Python parses back (proto2, groups and extensions)" do
    skip_without_python
    python_json_round_trip("proto2", ProtobufTestMessages::Proto2::TestAllTypesProto2, 9, 100)
  end
end

# Python writes JSON (with and without default values / proto names) and
# binary for random messages. Crystal must parse the JSON into the same
# message as the binary, and its own JSON (printed with varying options)
# must parse in Python into the original message.
private def python_json_round_trip(kind : String, type : T.class, seed : Int32, count : Int32) forall T
  path = PythonRoundTrip.generate_json(kind, seed, count)
  originals = ProtobufSpec.tmp_path("#{kind}-#{seed}-originals.bin")
  crystal = ProtobufSpec.tmp_path("#{kind}-#{seed}-crystal-json.bin")
  begin
    records = PythonRoundTrip.read_messages(path)
    records.size.should eq(count * 2)
    binaries = [] of Bytes
    jsons = [] of Bytes
    records.each_slice(2).with_index do |(json, binary), i|
      from_binary = type.from_protobuf(binary)
      from_json = type.from_json(String.new(json))
      message_should_eq(from_json, from_binary)
      options = Protobuf::JSON::PrintOptions.new(emit_defaults: i % 3 == 0, preserve_proto_field_names: i % 2 == 0, enums_as_ints: i % 5 == 0)
      printed = from_binary.to_json(options)
      message_should_eq(type.from_json(printed), from_binary)
      binaries << binary
      jsons << printed.to_slice
    end
    PythonRoundTrip.write_messages(originals, binaries)
    PythonRoundTrip.write_messages(crystal, jsons)
    PythonRoundTrip.check(kind, originals, crystal, "check-json").should contain("ok #{count}")
  ensure
    File.delete?(path)
    File.delete?(originals)
    File.delete?(crystal)
  end
end
