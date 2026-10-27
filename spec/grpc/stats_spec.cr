require "./grpc_helper"

private class RecordingStats < GRPC::StatsHandler
  getter events = [] of {UInt64, String, GRPC::Stats::Event}
  @mutex = Mutex.new

  def handle(rpc : GRPC::Stats::RPCInfo, event : GRPC::Stats::Event) : Nil
    @mutex.synchronize { @events << {rpc.id, rpc.method_path, event} }
  end

  def names(path : String) : Array(String)
    @mutex.synchronize { @events.select { |e| e[1] == path }.map(&.[2].class.name.split("::").last) }
  end

  def find(type : T.class) : Array(T) forall T
    @mutex.synchronize { @events.compact_map { |e| e[2].as?(T) } }
  end
end

private class RaisingStats < GRPC::StatsHandler
  def handle(rpc : GRPC::Stats::RPCInfo, event : GRPC::Stats::Event) : Nil
    raise "boom"
  end
end

private def wait_until(&) : Nil
  until yield
    sleep 10.milliseconds
  end
end

describe GRPC::Stats do
  it "emits the lifecycle of a unary call" do
    stats = RecordingStats.new
    GRPCSpec.with_server(server: GRPC::Server.new(stats_handlers: [stats] of GRPC::StatsHandler)) do |h|
      h.client.unary(GrpcSpec::EchoRequest.new(message: "hi", headers: {"x-h" => "v"}, trailers: {"x-t" => "w"}),
        metadata: {"x-in" => "1"})
      GRPCSpec.within { wait_until { stats.find(GRPC::Stats::End).size == 1 } }
      stats.names("/grpc_spec.TestService/Unary").should eq(%w(Begin InHeader InPayload OutHeader OutPayload Trailer End))
      stats.find(GRPC::Stats::InHeader).first.metadata["x-in"].should eq("1")
      stats.find(GRPC::Stats::OutHeader).first.metadata["x-h"].should eq("v")
      stats.find(GRPC::Stats::Trailer).first.metadata["x-t"].should eq("w")
      payload = stats.find(GRPC::Stats::InPayload).first
      payload.message.should be_a(GrpcSpec::EchoRequest)
      payload.wire_length.should eq(payload.length + 5)
      finish = stats.find(GRPC::Stats::End).first
      finish.status.ok?.should be_true
      finish.messages_sent.should eq(1)
      finish.messages_received.should eq(1)
      stats.events.map(&.[0]).uniq.size.should eq(1)
    end
  end

  it "reports failed and streaming calls" do
    stats = RecordingStats.new
    GRPCSpec.with_server(server: GRPC::Server.new(stats_handlers: [stats] of GRPC::StatsHandler)) do |h|
      expect_raises(GRPC::Error) { h.client.unary(GrpcSpec::EchoRequest.new(status_code: 7)) }
      h.client.server_stream(GrpcSpec::EchoRequest.new(count: 3)).to_a
      GRPCSpec.within { wait_until { stats.find(GRPC::Stats::End).size == 2 } }
      ends = stats.find(GRPC::Stats::End)
      ends.map(&.status.code).should contain(GRPC::StatusCode::PermissionDenied)
      ends.find(&.status.ok?).not_nil!.messages_sent.should eq(3)
    end
  end

  it "keeps serving when a handler raises" do
    GRPCSpec.with_server(server: GRPC::Server.new(stats_handlers: [RaisingStats.new] of GRPC::StatsHandler)) do |h|
      h.client.unary(GrpcSpec::EchoRequest.new(message: "ok")).message.should eq("ok")
    end
  end

  describe GRPC::MetricsCollector do
    it "aggregates per-method counters and latencies" do
      metrics = GRPC::MetricsCollector.new
      server = GRPC::Server.new
      server.add_stats_handler(metrics)
      GRPCSpec.with_server(server: server) do |h|
        3.times { h.client.unary(GrpcSpec::EchoRequest.new(message: "m")) }
        expect_raises(GRPC::Error) { h.client.unary(GrpcSpec::EchoRequest.new(status_code: 5)) }
        GRPCSpec.within do
          wait_until { metrics.snapshot["/grpc_spec.TestService/Unary"]?.try(&.completed.values.sum) == 4 }
        end
        stats = metrics.snapshot["/grpc_spec.TestService/Unary"]
        stats.started.should eq(4)
        stats.in_flight.should eq(0)
        stats.completed[GRPC::StatusCode::Ok].should eq(3)
        stats.completed[GRPC::StatusCode::NotFound].should eq(1)
        stats.messages_received.should eq(4)
        stats.latency_buckets.sum.should eq(4)
        stats.bytes_sent.should be > 0
      end
    end
  end
end

describe "GRPC::Server#handle_unknown" do
  it "passes calls to unregistered methods to a generic handler" do
    server = GRPC::Server.new
    server.handle_unknown do |call|
      path = call.context.method_path
      while bytes = call.read_raw_message
        request = GrpcSpec::EchoRequest.from_protobuf(bytes)
        call.send_raw_message(GrpcSpec::EchoResponse.new(message: "#{path}:#{request.message}").to_protobuf)
      end
    end
    GRPCSpec.with_server(server: server) do |h|
      response = GRPC::Client.new(h.channel).call_unary("/proxy.Svc/Do",
        GrpcSpec::EchoRequest.new(message: "x"), GrpcSpec::EchoResponse)
      response.message.should eq("/proxy.Svc/Do:x")

      call = GRPC::Client.new(h.channel).call_bidi_streaming("/proxy.Svc/Stream", GrpcSpec::EchoRequest, GrpcSpec::EchoResponse)
      call.send(GrpcSpec::EchoRequest.new(message: "a"))
      call.send(GrpcSpec::EchoRequest.new(message: "b"))
      call.close_send
      call.map(&.message).to_a.should eq(["/proxy.Svc/Stream:a", "/proxy.Svc/Stream:b"])
    end
  end
end

describe "client-side stats" do
  it "emits the lifecycle of client calls" do
    stats = RecordingStats.new
    GRPCSpec.with_server do |h|
      channel = GRPC::Channel.new(h.address, stats_handlers: [stats] of GRPC::StatsHandler)
      client = GrpcSpec::TestService::Client.new(channel)
      begin
        client.unary(GrpcSpec::EchoRequest.new(message: "c", headers: {"x-h" => "v"}, trailers: {"x-t" => "w"}))
        stats.names("/grpc_spec.TestService/Unary").should eq(%w(Begin OutHeader OutPayload InHeader InPayload Trailer End))
        stats.find(GRPC::Stats::InHeader).first.metadata["x-h"].should eq("v")
        stats.find(GRPC::Stats::Trailer).first.metadata["x-t"].should eq("w")
        stats.events.all? { |(id, _, _)| id == stats.events.first[0] }.should be_true

        expect_raises(GRPC::Error) { client.unary(GrpcSpec::EchoRequest.new(status_code: 3)) }
        client.server_stream(GrpcSpec::EchoRequest.new(count: 2)).to_a
        ends = stats.find(GRPC::Stats::End)
        ends.size.should eq(3)
        ends[1].status.code.should eq(GRPC::StatusCode::InvalidArgument)
        ends[2].messages_received.should eq(2)
      ensure
        channel.close
      end
    end
  end

  it "reports calls that fail before reaching a server" do
    stats = RecordingStats.new
    channel = GRPC::Channel.new("127.0.0.1:1", stats_handlers: [stats] of GRPC::StatsHandler)
    client = GrpcSpec::TestService::Client.new(channel)
    expect_raises(GRPC::Error) { client.unary(GrpcSpec::EchoRequest.new, deadline: 2.seconds) }
    stats.find(GRPC::Stats::End).first.status.code.should eq(GRPC::StatusCode::Unavailable)
    channel.close
  end
end
