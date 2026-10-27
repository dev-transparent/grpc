require "./grpc_helper"
require "../../src/grpc/reflection"

private alias V1 = Grpc::Reflection::V1
private alias V1Alpha = Grpc::Reflection::V1alpha

private def with_reflection(&block : GRPCSpec::Harness, V1::ServerReflection::Client ->) : Nil
  server = GRPC::Server.new
  GRPC::Reflection.enable(server)
  GRPCSpec.with_server(server: server) do |h|
    block.call(h, V1::ServerReflection::Client.new(h.channel))
  end
end

private def ask(client : V1::ServerReflection::Client, *requests : V1::ServerReflectionRequest) : Array(V1::ServerReflectionResponse)
  call = client.server_reflection_info(deadline: 5.seconds)
  responses = requests.map do |request|
    call.send(request)
    call.receive?.not_nil!
  end
  call.close_send
  call.receive?.should be_nil
  responses.to_a
end

private def file_names(response : V1::ServerReflectionResponse) : Array(String)
  response.file_descriptor_response.not_nil!.file_descriptor_proto.map do |bytes|
    Google::Protobuf::FileDescriptorProto.from_protobuf(bytes).name.not_nil!
  end
end

describe GRPC::Reflection do
  it "lists the registered services" do
    with_reflection do |_, client|
      response = ask(client, V1::ServerReflectionRequest.new(list_services: "", host: "h")).first
      response.valid_host.should eq("h")
      response.original_request.not_nil!.list_services.should eq("")
      response.list_services_response.not_nil!.service.map(&.name).should eq([
        "grpc.reflection.v1.ServerReflection", "grpc.reflection.v1alpha.ServerReflection", "grpc_spec.TestService",
      ])
    end
  end

  it "returns files by name with their dependencies" do
    with_reflection do |_, client|
      response = ask(client, V1::ServerReflectionRequest.new(file_by_filename: "grpc/reflection/v1/reflection.proto")).first
      file_names(response).should eq(["grpc/reflection/v1/reflection.proto"])
      descriptor = Google::Protobuf::FileDescriptorProto.from_protobuf(response.file_descriptor_response.not_nil!.file_descriptor_proto.first)
      descriptor.service.first.name.should eq("ServerReflection")
    end
  end

  it "finds the files containing services, methods, messages, fields and enums" do
    with_reflection do |_, client|
      %w(grpc_spec.TestService grpc_spec.TestService.Unary .grpc_spec.EchoRequest grpc_spec.EchoRequest.message).each do |symbol|
        response = ask(client, V1::ServerReflectionRequest.new(file_containing_symbol: symbol)).first
        response.error_response.should be_nil
        file_names(response).first.should eq("test_service.proto")
      end
    end
  end

  it "sends each dependency once per stream" do
    with_reflection do |_, client|
      first, second = ask(client,
        V1::ServerReflectionRequest.new(file_containing_symbol: "google.protobuf.Timestamp"),
        V1::ServerReflectionRequest.new(file_containing_symbol: "google.protobuf.Timestamp"))
      file_names(first).should eq(["google/protobuf/timestamp.proto"])
      file_names(second).should eq(["google/protobuf/timestamp.proto"])

      any, api = ask(client,
        V1::ServerReflectionRequest.new(file_by_filename: "google/protobuf/source_context.proto"),
        V1::ServerReflectionRequest.new(file_by_filename: "google/protobuf/api.proto"))
      file_names(any).should eq(["google/protobuf/source_context.proto"])
      # api.proto depends on source_context.proto (already sent) and type.proto.
      file_names(api).should contain("google/protobuf/api.proto")
      file_names(api).should_not contain("google/protobuf/source_context.proto")
    end
  end

  it "reports extension numbers and files containing extensions" do
    with_reflection do |_, client|
      numbers = ask(client, V1::ServerReflectionRequest.new(all_extension_numbers_of_type: "google.protobuf.FileOptions")).first
      numbers.all_extension_numbers_response.not_nil!.base_type_name.should eq("google.protobuf.FileOptions")

      Protobuf::Registry.extension_numbers("google.protobuf.FileOptions").first?.try do |number|
        response = ask(client, V1::ServerReflectionRequest.new(file_containing_extension: V1::ExtensionRequest.new(containing_type: "google.protobuf.FileOptions", extension_number: number))).first
        response.file_descriptor_response.should_not be_nil
      end
    end
  end

  it "returns NOT_FOUND errors in the stream" do
    with_reflection do |_, client|
      responses = ask(client,
        V1::ServerReflectionRequest.new(file_by_filename: "missing.proto"),
        V1::ServerReflectionRequest.new(file_containing_symbol: "no.Such"),
        V1::ServerReflectionRequest.new(all_extension_numbers_of_type: "no.Such"),
        V1::ServerReflectionRequest.new(file_containing_extension: V1::ExtensionRequest.new(containing_type: "no.Such", extension_number: 1)),
        V1::ServerReflectionRequest.new)
      responses[0..3].each { |r| r.error_response.not_nil!.error_code.should eq(GRPC::StatusCode::NotFound.value) }
      responses[4].error_response.not_nil!.error_code.should eq(GRPC::StatusCode::InvalidArgument.value)
    end
  end

  it "serves the v1alpha protocol" do
    with_reflection do |h, _|
      client = V1Alpha::ServerReflection::Client.new(h.channel)
      call = client.server_reflection_info(deadline: 5.seconds)
      call.send(V1Alpha::ServerReflectionRequest.new(file_containing_symbol: "grpc_spec.TestService"))
      response = call.receive?.not_nil!
      call.close_send
      response.file_descriptor_response.not_nil!.file_descriptor_proto.size.should be > 0
    end
  end

  it "works with the official grpcio reflection client" do
    python = ENV["PYTHON"]? || "/tmp/grpc-venv-dir/venv/bin/python"
    unless File.exists?(python) && Process.run(python, ["-c", "import grpc_reflection"]).success?
      pending!("grpcio-reflection not available")
    end
    with_reflection do |h, _|
      script = <<-PY
        import sys, grpc
        from grpc_reflection.v1alpha.proto_reflection_descriptor_database import ProtoReflectionDescriptorDatabase
        from google.protobuf.descriptor_pool import DescriptorPool
        from google.protobuf import message_factory
        channel = grpc.insecure_channel(sys.argv[1])
        db = ProtoReflectionDescriptorDatabase(channel)
        pool = DescriptorPool(db)
        service = pool.FindServiceByName("grpc_spec.TestService")
        req = message_factory.GetMessageClass(pool.FindMessageTypeByName("grpc_spec.EchoRequest"))
        rep = message_factory.GetMessageClass(pool.FindMessageTypeByName("grpc_spec.EchoResponse"))
        call = channel.unary_unary("/grpc_spec.TestService/Unary", request_serializer=req.SerializeToString, response_deserializer=rep.FromString)
        print(",".join(sorted(db.get_services())), [m.name for m in service.methods][0], call(req(message="py")).message)
        PY
      output = IO::Memory.new
      status = Process.run(python, ["-c", script, h.address], output: output, error: output)
      status.success?.should be_true
      output.to_s.should contain("grpc_spec.TestService")
      output.to_s.should contain("Unary py")
    end
  end
end
