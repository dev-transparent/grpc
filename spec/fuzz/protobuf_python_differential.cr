# Differential fuzzing of the binary decoder against Python's protobuf
# (upb): mutated conformance messages must be accepted or rejected by both,
# and when accepted Crystal's re-encoding must decode in Python to the same
# message.
require "./protobuf_fuzz_support"

module ProtobufFuzz
  class PythonDifferential
    SCRIPT  = File.join(ROOT, "spec", "protobuf", "python", "roundtrip.py")
    WORKDIR = File.join(ROOT, "tmp", "fuzz", "python")
    GEN_DIR = File.join(WORKDIR, "gen")
    KINDS   = {
      "proto3" => "protobuf_test_messages.proto3.TestAllTypesProto3",
      "proto2" => "protobuf_test_messages.proto2.TestAllTypesProto2",
    }

    getter findings = [] of Finding
    getter executions = 0
    @prepared : Bool? = nil

    def initialize(seed : UInt64, @python : String = ENV["PYTHON"]? || "/tmp/grpc-venv-dir/venv/bin/python")
      @random = Random.new(seed)
    end

    def available? : Bool
      if (prepared = @prepared).nil?
        @prepared = prepared = prepare
      end
      prepared
    end

    private def run(args : Array(String)) : {Bool, String}
      output = IO::Memory.new
      status = Process.run(@python, args, output: output, error: output)
      {status.success?, output.to_s}
    rescue File::NotFoundError | IO::Error
      {false, "#{@python} not found"}
    end

    private def prepare : Bool
      ok, _ = run(["-c", "import google.protobuf, grpc_tools.protoc"])
      return false unless ok
      proto_dir = File.join(WORKDIR, "proto", "conformance")
      Dir.mkdir_p(proto_dir)
      Dir.mkdir_p(GEN_DIR)
      %w(test_messages_proto3.proto test_messages_proto2.proto).each do |name|
        File.copy(File.join(ROOT, "spec", "protobuf", "proto", "google", "protobuf", name), File.join(proto_dir, name))
      end
      ok, output = run(["-m", "grpc_tools.protoc", "-I#{File.join(WORKDIR, "proto")}", "--python_out=#{GEN_DIR}",
                        "conformance/test_messages_proto3.proto", "conformance/test_messages_proto2.proto"])
      raise "grpc_tools.protoc failed: #{output}" unless ok
      true
    end

    # Runs *count* mutated inputs per message kind through both decoders.
    def run(count : Int32) : Nil
      KINDS.each do |kind, type_name|
        klass = Protobuf::Registry.message_class(type_name)
        generator = WireGenerator.new(@random)
        seeds = Array.new(8) { generator.generate(type_name) }
        mutator = Mutator.new(@random, seeds)
        inputs = Array.new(count) { @random.rand < 0.1 ? seeds.sample(@random) : mutator.mutate(seeds.sample(@random)) }
        results = inputs.map do |input|
          @executions += 1
          begin
            encoded = klass.from_protobuf(input).to_protobuf
            Bytes.new(encoded.size + 1).tap do |bytes|
              bytes[0] = 1_u8
              encoded.copy_to(bytes + 1)
            end
          rescue Protobuf::DecodeError
            Bytes[0]
          rescue ex
            @findings << Finding.new("python", input, "#{kind}: #{ex.class}: #{ex.message}")
            Bytes[0]
          end
        end
        compare(kind, inputs, results)
      end
    end

    private def compare(kind : String, inputs : Array(Bytes), results : Array(Bytes)) : Nil
      Dir.mkdir_p(WORKDIR)
      inputs_path = File.join(WORKDIR, "#{Process.pid}-inputs.bin")
      results_path = File.join(WORKDIR, "#{Process.pid}-results.bin")
      write(inputs_path, inputs)
      write(results_path, results)
      ok, output = run([SCRIPT, GEN_DIR, "diff", kind, inputs_path, results_path])
      raise "python diff failed: #{output}" unless ok
      output.each_line do |line|
        next unless line.starts_with?("MISMATCH ")
        index = line.split(' ')[1].to_i
        @findings << Finding.new("python", inputs[index], "#{kind}: #{line}")
      end
    ensure
      File.delete?(inputs_path) if inputs_path
      File.delete?(results_path) if results_path
    end

    private def write(path : String, records : Array(Bytes)) : Nil
      File.open(path, "wb") do |file|
        records.each do |record|
          file.write_bytes(record.size.to_u32, IO::ByteFormat::BigEndian)
          file.write(record)
        end
      end
    end
  end
end
