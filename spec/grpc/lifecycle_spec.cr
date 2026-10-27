require "./grpc_helper"

include GRPCSpec

private def start_server(port : Int32 = 0, impl = TestServiceImpl.new) : {GRPC::Server, Int32}
  server = GRPC::Server.new
  server.handle(impl)
  address = server.bind_tcp("127.0.0.1", port)
  server.start
  {server, address.port}
end

describe "GRPC server lifecycle" do
  it "lets in-flight calls finish on graceful close and refuses new calls" do
    impl = TestServiceImpl.new
    server, port = start_server(impl: impl)
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    client = Client.new(channel)
    begin
      GRPCSpec.within do
        server.services.size.should eq 1
        unary = GRPCSpec.async { client.unary(EchoRequest.new(message: "in flight", sleep_ms: 300)).message }
        stream_call = client.server_stream(EchoRequest.new(count: 5, sleep_ms: 50))
        impl.events.wait_for("start Unary")
        impl.events.wait_for("start ServerStream")

        closed = GRPCSpec.async { server.close(5.seconds); true }
        GRPCSpec.await(unary).should eq "in flight"
        stream_call.to_a.size.should eq 5
        GRPCSpec.await(closed).should be_true
        server.closed?.should be_true
        impl.events.to_a.any?(&.starts_with?("on_cancel")).should be_false

        GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.unary(EchoRequest.new) }
      end
    ensure
      channel.close
      server.close(1.second)
    end
  end

  it "stops waiting for calls that outlive the close timeout" do
    impl = TestServiceImpl.new
    server, port = start_server(impl: impl)
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    client = Client.new(channel)
    begin
      GRPCSpec.within do
        call = GRPCSpec.async { client.unary(EchoRequest.new(sleep_ms: 10_000)) }
        impl.events.wait_for("start Unary")
        start = Time.instant
        server.close(200.milliseconds)
        (Time.instant - start).should be < 3.seconds
        result = GRPCSpec.await(call)
        result.should be_a(GRPC::Error)
        result.as(GRPC::Error).code.should eq GRPC::StatusCode::Unavailable
        impl.events.wait_for { |e| e.starts_with?("on_cancel Unary") }
      end
    ensure
      channel.close
    end
  end

  it "reconnects after the server restarts on the same port" do
    server, port = start_server
    channel = GRPC::Channel.new("127.0.0.1:#{port}")
    client = Client.new(channel)
    begin
      GRPCSpec.within do
        client.unary(EchoRequest.new(message: "before")).message.should eq "before"
        server.close(1.second)

        GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.unary(EchoRequest.new) }

        server, _ = start_server(port)
        # The failed reconnect put the channel in connection backoff and
        # pick_first stays in TRANSIENT_FAILURE until a connection is READY
        # (gRFC A62): reset the backoff and wait for the reconnect.
        channel.reset_connect_backoff
        channel.connect(5.seconds).should be_true
        client.unary(EchoRequest.new(message: "after")).message.should eq "after"

        # Without resetting, a wait-for-ready call rides out the backoff.
        server.close(1.second)
        GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.unary(EchoRequest.new) }
        server, _ = start_server(port)
        client.with_options(wait_for_ready: true).unary(EchoRequest.new(message: "again"), deadline: 5.seconds).message.should eq "again"
        client.server_stream(EchoRequest.new(count: 2)).to_a.size.should eq 2
      end
    ensure
      channel.close
      server.close(1.second)
    end
  end

  it "fails with UNAVAILABLE when nothing is listening" do
    server, port = start_server
    server.close(1.second)
    client = Client.new(GRPC::Channel.new("127.0.0.1:#{port}"))
    GRPCSpec.within do
      GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.unary(EchoRequest.new) }
      GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.server_stream(EchoRequest.new).to_a }
      GRPCSpec.expect_status(GRPC::StatusCode::Unavailable) { client.bidi }
    end
  end

  it "reopens the connection after the channel is closed" do
    GRPCSpec.with_server do |h|
      h.client.ping(Empty.new)
      h.channel.close
      h.client.ping(Empty.new).should eq Empty.new
    end
  end

  it "serves multiple channels" do
    GRPCSpec.with_server do |h|
      channels = Array.new(3) { GRPC::Channel.new(h.address) }
      begin
        channels.each_with_index do |channel, i|
          Client.new(channel).unary(EchoRequest.new(message: i.to_s)).message.should eq i.to_s
        end
      ensure
        channels.each(&.close)
      end
    end
  end

  it "serves connections over custom transports" do
    server = GRPC::Server.new
    server.handle(TestServiceImpl.new)
    channel = GRPC::Channel.new("in-memory") do
      client_io, server_io = UNIXSocket.pair
      spawn { server.handle_connection(server_io) }
      client_io.as(IO)
    end
    begin
      GRPCSpec.within do
        Client.new(channel).unary(EchoRequest.new(message: "pipe")).message.should eq "pipe"
      end
    ensure
      channel.close
      server.close(1.second)
    end
  end
end
