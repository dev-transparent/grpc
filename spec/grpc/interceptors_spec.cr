require "./grpc_helper"

include GRPCSpec

class RecordingServerInterceptor < GRPC::ServerInterceptor
  def initialize(@name : String, @log : GRPCSpec::Events)
  end

  def call(context : GRPC::ServerContext, continuation : -> Nil) : Nil
    @log << "#{@name} before #{context.method_name}"
    context.response_metadata.add("x-interceptor", @name)
    begin
      continuation.call
    rescue e : GRPC::Error
      @log << "#{@name} saw #{e.code}"
      raise e
    end
    @log << "#{@name} after"
  end
end

class RecordingClientInterceptor < GRPC::ClientInterceptor
  def initialize(@name : String, @log : Array(String))
  end

  def call(info : GRPC::CallInfo, continuation : -> GRPC::ClientCall) : GRPC::ClientCall
    @log << "#{@name} #{info.method_path}"
    info.metadata.add("x-client-interceptor", @name)
    call = continuation.call
    @log << "#{@name} started"
    call
  end
end

describe "GRPC server interceptors" do
  it "run in the order they were added around the handler" do
    server = GRPC::Server.new
    log = GRPCSpec::Events.new
    server.intercept(RecordingServerInterceptor.new("outer", log))
    server.intercept(RecordingServerInterceptor.new("inner", log))
    GRPCSpec.with_server(server: server) do |h|
      call = h.client.unary_call(EchoRequest.new)
      call.response
      call.headers.get_all("x-interceptor").should eq ["outer", "inner"]
      log.to_a.should eq ["outer before Unary", "inner before Unary", "inner after", "outer after"]
    end
  end

  it "wrap streaming handlers and see their errors" do
    server = GRPC::Server.new
    log = GRPCSpec::Events.new
    server.intercept(RecordingServerInterceptor.new("only", log))
    GRPCSpec.with_server(server: server) do |h|
      h.client.server_stream(EchoRequest.new(count: 2)).to_a.size.should eq 2
      log.to_a.should eq ["only before ServerStream", "only after"]

      call = h.client.bidi
      call << EchoRequest.new(status_code: 3)
      GRPCSpec.expect_status(GRPC::StatusCode::InvalidArgument) { call.to_a }
      log.wait_for("only saw InvalidArgument")
    end
  end

  it "can read request metadata and add trailers" do
    server = GRPC::Server.new
    server.intercept do |context, continuation|
      context.trailers.add("x-seen-token", context.metadata["authorization"]? || "none")
      continuation.call
    end
    GRPCSpec.with_server(server: server) do |h|
      call = h.client.unary_call(EchoRequest.new, metadata: {"authorization" => "Bearer abc"})
      call.response
      call.trailers["x-seen-token"].should eq "Bearer abc"
    end
  end

  it "can reject calls without running the handler" do
    server = GRPC::Server.new
    server.intercept do |context, continuation|
      unless context.metadata["authorization"]? == "Bearer secret"
        raise GRPC::Error.new(:unauthenticated, "Invalid token", metadata: GRPC::Metadata{"www-authenticate" => "Bearer"})
      end
      continuation.call
    end
    GRPCSpec.with_server(server: server) do |h|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Unauthenticated) { h.client.unary(EchoRequest.new) }
      error.status.message.should eq "Invalid token"
      error.metadata["www-authenticate"].should eq "Bearer"

      GRPCSpec.expect_status(GRPC::StatusCode::Unauthenticated) do
        h.client.client_stream { |c| c << EchoRequest.new }
      end
      h.events.to_a.should be_empty # the handler never ran

      h.client.unary(EchoRequest.new(message: "ok"), metadata: {"authorization" => "Bearer secret"}).message.should eq "ok"
    end
  end

  it "maps unhandled interceptor exceptions to UNKNOWN" do
    server = GRPC::Server.new
    server.intercept { |_, _| raise "interceptor bug" }
    GRPCSpec.with_server(server: server) do |h|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Unknown) { h.client.unary(EchoRequest.new) }
      error.status.message.should eq "interceptor bug"
    end
  end
end

describe "GRPC client interceptors" do
  it "run in the order they were added and can add metadata" do
    GRPCSpec.with_server do |h|
      log = [] of String
      client = h.new_client(interceptors: [RecordingClientInterceptor.new("first", log)] of GRPC::ClientInterceptor)
      client.intercept(RecordingClientInterceptor.new("second", log))
      response = client.unary(EchoRequest.new)
      log.should eq [
        "first /grpc_spec.TestService/Unary", "second /grpc_spec.TestService/Unary",
        "second started", "first started",
      ]
      # Metadata only keeps the last value per key in the echo.
      response.metadata["x-client-interceptor"].should eq "second".to_slice

      call = client.unary_call(EchoRequest.new, metadata: {"x-echo-initial" => "x"})
      call.response
      log.size.should eq 8
    end
  end

  it "apply to all call kinds" do
    GRPCSpec.with_server do |h|
      paths = [] of String
      client = h.new_client
      client.intercept do |info, continuation|
        paths << info.method_path
        info.metadata["x-echo-trailing"] = "from-interceptor"
        continuation.call
      end
      client.unary(EchoRequest.new)
      stream = client.server_stream(EchoRequest.new(count: 1))
      stream.to_a
      stream.trailers["x-echo-trailing"].should eq "from-interceptor"
      client.client_stream { |c| c << EchoRequest.new }
      bidi = client.bidi
      bidi.close_send
      bidi.to_a
      paths.should eq ["/grpc_spec.TestService/Unary", "/grpc_spec.TestService/ServerStream",
                       "/grpc_spec.TestService/ClientStream", "/grpc_spec.TestService/Bidi"]
    end
  end

  it "can set the deadline" do
    GRPCSpec.with_server do |h|
      client = h.new_client
      client.intercept do |info, continuation|
        info.deadline.should be_nil
        info.timeout = 100.milliseconds
        continuation.call
      end
      GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) { client.unary(EchoRequest.new(sleep_ms: 5_000)) }
    end
  end

  it "can reject calls before they are sent" do
    GRPCSpec.with_server do |h|
      client = h.new_client
      client.intercept do |info, continuation|
        raise GRPC::Error.new(:permission_denied, "blocked by client") if info.metadata["x-block"]?
        continuation.call
      end
      error = GRPCSpec.expect_status(GRPC::StatusCode::PermissionDenied) do
        client.unary(EchoRequest.new, metadata: {"x-block" => "1"})
      end
      error.status.message.should eq "blocked by client"
      h.events.to_a.should be_empty
      client.unary(EchoRequest.new(message: "allowed")).message.should eq "allowed"
    end
  end

  it "see default metadata and do not leak changes into it" do
    GRPCSpec.with_server do |h|
      client = h.new_client(metadata: {"x-default" => "d"})
      seen = [] of String?
      client.intercept do |info, continuation|
        seen << info.metadata["x-default"]?
        info.metadata["x-added"] = "a"
        continuation.call
      end
      client.unary(EchoRequest.new)
      client.unary(EchoRequest.new)
      seen.should eq ["d", "d"]
      client.metadata.has_key?("x-added").should be_false
    end
  end
end
