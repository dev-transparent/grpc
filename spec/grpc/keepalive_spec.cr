require "./grpc_helper"
require "../support/fault_proxy"

# Records the client address of every call to observe reconnections.
private class PeerRecorder < GRPC::ServerInterceptor
  getter peers = Set(String).new
  @mutex = Mutex.new

  def call(context : GRPC::ServerContext, continuation : -> Nil) : Nil
    @mutex.synchronize { context.peer.try { |peer| @peers << peer } }
    continuation.call
  end

  def count : Int32
    @mutex.synchronize { @peers.size }
  end
end

private def options(& : HTTP2::ConnectionOptions -> HTTP2::ConnectionOptions) : HTTP2::ConnectionOptions
  yield HTTP2::Server.default_options
end

describe "gRPC keepalive and connection management" do
  it "keeps calls succeeding while the server ages out connections" do
    recorder = PeerRecorder.new
    server = GRPC::Server.new(connection_options: options { |o| o.max_connection_age = 300.milliseconds; o.max_connection_age_grace = 5.seconds; o })
    server.intercept(recorder)
    GRPCSpec.with_server(server: server) do |h|
      started = Time.instant
      count = 0
      while Time.instant - started < 1.5.seconds
        h.client.unary(GrpcSpec::EchoRequest.new(message: "age")).message.should eq("age")
        # A slow call spanning a GOAWAY still completes within the grace period.
        h.client.unary(GrpcSpec::EchoRequest.new(sleep_ms: 50)) if count % 10 == 0
        count += 1
        sleep 5.milliseconds
      end
      recorder.count.should be >= 3
    end
  end

  it "closes idle connections and reconnects on demand" do
    recorder = PeerRecorder.new
    server = GRPC::Server.new(connection_options: options { |o| o.max_connection_idle = 200.milliseconds; o })
    server.intercept(recorder)
    GRPCSpec.with_server(server: server) do |h|
      h.client.unary(GrpcSpec::EchoRequest.new(message: "1"))
      deadline = Time.instant + 3.seconds
      until h.channel.state.idle? || Time.instant > deadline
        sleep 20.milliseconds
      end
      h.channel.state.should eq(GRPC::ConnectivityState::Idle)
      h.client.unary(GrpcSpec::EchoRequest.new(message: "2")).message.should eq("2")
      recorder.count.should eq(2)
    end
  end

  it "detects a dead connection with client keepalive and fails in-flight calls" do
    GRPCSpec.with_server do |h|
      port = h.address.split(':').last.to_i
      proxy = FaultProxy.new("127.0.0.1", port)
      channel = GRPC::Channel.new("127.0.0.1:#{proxy.port}",
        keepalive: GRPC::KeepaliveOptions.new(200.milliseconds, 300.milliseconds, permit_without_calls: true))
      client = GrpcSpec::TestService::Client.new(channel)
      begin
        client.unary(GrpcSpec::EchoRequest.new(message: "up")).message.should eq("up")
        call = GRPCSpec.async { client.unary(GrpcSpec::EchoRequest.new(sleep_ms: 5_000)) }
        sleep 50.milliseconds
        proxy.black_hole_connections = true
        proxy.pause # stop forwarding in both directions: the peer is silently gone
        started = Time.instant
        result = GRPCSpec.await(call, 5.seconds)
        result.should be_a(GRPC::Error)
        result.as(GRPC::Error).code.should eq(GRPC::StatusCode::Unavailable)
        (Time.instant - started).should be < 2.seconds
      ensure
        channel.shutdown
        proxy.close
      end
    end
  end

  it "survives the server rejecting aggressive keepalive pings" do
    GRPCSpec.with_server do |h|
      # The default server policy allows pings every 5 minutes, and none
      # without calls; this client pings every 50ms even when idle.
      channel = GRPC::Channel.new(h.address,
        keepalive: GRPC::KeepaliveOptions.new(50.milliseconds, 1.second, permit_without_calls: true))
      client = GrpcSpec::TestService::Client.new(channel)
      begin
        client.unary(GrpcSpec::EchoRequest.new(message: "a")).message.should eq("a")
        sleep 400.milliseconds # long enough to collect strikes and receive GOAWAY(too_many_pings)
        5.times { client.unary(GrpcSpec::EchoRequest.new(message: "b"), deadline: 5.seconds).message.should eq("b") }
      ensure
        channel.shutdown
      end
    end
  end

  it "accepts pings allowed by a permissive server policy" do
    server = GRPC::Server.new(connection_options: options { |o| o.min_ping_interval = 10.milliseconds; o.permit_without_stream = true; o })
    recorder = PeerRecorder.new
    server.intercept(recorder)
    GRPCSpec.with_server(server: server) do |h|
      channel = GRPC::Channel.new(h.address,
        keepalive: GRPC::KeepaliveOptions.new(50.milliseconds, 1.second, permit_without_calls: true))
      client = GrpcSpec::TestService::Client.new(channel)
      begin
        client.unary(GrpcSpec::EchoRequest.new(message: "x"))
        sleep 400.milliseconds
        client.unary(GrpcSpec::EchoRequest.new(message: "y"))
        recorder.count.should eq(1) # the same connection survived
      ensure
        channel.shutdown
      end
    end
  end
end
