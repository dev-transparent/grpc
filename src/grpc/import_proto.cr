module GRPC
  # Generates messages, enums, service base classes and client stubs from a
  # `.proto` file at compile time, without `protoc`.
  #
  # ```
  # GRPC.import_proto "proto/helloworld.proto"
  #
  # class Greeter < Helloworld::Greeter::Service
  #   def say_hello(request, context)
  #     Helloworld::HelloReply.new(message: "Hello #{request.name}")
  #   end
  # end
  #
  # client = Helloworld::Greeter::Client.new("localhost:50051")
  # ```
  #
  # Accepts the same arguments as `Protobuf.import_proto`: extra include
  # paths for imports (relative to the calling file) and `dump: true` to
  # print the generated code at compile time.
  macro import_proto(path, *include_paths, dump = false)
    {% unless path.is_a?(StringLiteral) %}
      {% raise "GRPC.import_proto expects a string literal path, not #{path}" %}
    {% end %}
    {% base = path.filename ? path.filename.split("/")[0..-2].join("/") : "." %}
    {% code = run("../protobuf/compiler/import_runner", "--macro", "--base", base, "--grpc",
         "--includes", include_paths.map(&.id).join(","), path) %}
    {% if code.starts_with?("__PROTOBUF_IMPORT_ERROR__") %}
      {% path.raise code.gsub(/^__PROTOBUF_IMPORT_ERROR__/, "") %}
    {% end %}
    {% if dump %}
      {% puts code %}
    {% end %}
    {{code}}
  end
end
