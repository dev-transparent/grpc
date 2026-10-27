require "./client_helper"

private alias Code = GRPC::StatusCode

private def with_server(&block : ClientSpec::TestServer, GRPC::Channel ->) : Nil
  server = ClientSpec::TestServer.new
  channel = GRPC::Channel.new(server.address)
  begin
    GRPCSpec.within { block.call(server, channel) }
  ensure
    channel.shutdown
    server.close
  end
end

describe GRPC::CallOptions do
  it "merges options" do
    a = GRPC::CallOptions.new(wait_for_ready: true, compression: "gzip", timeout: 1.second, metadata: {"a" => "1"},
      call_credentials: GRPC::CallCredentials.bearer("a"))
    b = GRPC::CallOptions.new(wait_for_ready: false, max_receive_message_size: 10, metadata: {"b" => "2"},
      call_credentials: GRPC::CallCredentials.bearer("b"))
    merged = a.merge(b)
    merged.wait_for_ready.should be_false
    merged.compression.should eq "gzip"
    merged.timeout.should eq 1.second
    merged.max_receive_message_size.should eq 10
    merged.metadata.not_nil!.to_h.should eq({"a" => "1", "b" => "2"})
    merged.call_credentials.should be_a(GRPC::CallCredentials::Composite)
    expect_raises(ArgumentError) { GRPC::CallOptions.new(compression: "brotli") }
  end
end

describe "GRPC::Client per-call options" do
  it "returns configured copies with with_options" do
    with_server do |_, channel|
      client = ClientSpec::Client.new(channel, metadata: {"x-base" => "1"})
      copy = client.with_options(metadata: {"x-extra" => "2"}, timeout: 2.seconds, wait_for_ready: true)
      copy.should_not be(client)
      copy.channel.should be(channel)
      copy.wait_for_ready.should be_true
      client.wait_for_ready.should be_nil
      response = copy.unary(ClientSpec::EchoRequest.new)
      response.metadata.keys.should contain "x-base"
      response.metadata.keys.should contain "x-extra"
      response.timeout_ms.should be_close(2000, 300)
      client.unary(ClientSpec::EchoRequest.new).metadata.keys.should_not contain "x-extra"
    end
  end

  it "accepts CallOptions on the call helpers" do
    with_server do |_, channel|
      client = ClientSpec::Client.new(channel)
      options = GRPC::CallOptions.new(metadata: {"x-opt" => "yes"}, compression: "gzip", timeout: 3.seconds)
      response = client.call_unary(ClientSpec::UNARY, ClientSpec::EchoRequest.new, ClientSpec::EchoResponse, options: options)
      String.new(response.metadata["x-opt"]).should eq "yes"
      response.request_compressed.should be_true
      response.timeout_ms.should be_close(3000, 300)

      stream = client.call_server_streaming(ClientSpec::SERVER_STREAM, ClientSpec::EchoRequest.new(count: 2),
        ClientSpec::EchoResponse, nil, nil, options)
      stream.to_a.size.should eq 2
      bidi = client.call_bidi_streaming(ClientSpec::BIDI, ClientSpec::EchoRequest, ClientSpec::EchoResponse, options: options)
      bidi << ClientSpec::EchoRequest.new(message: "b")
      bidi.close_send
      bidi.to_a.map(&.request_compressed).should eq [true]
    end
  end

  it "enforces max_send_message_size" do
    with_server do |server, channel|
      client = ClientSpec::Client.new(channel, max_send_message_size: 100)
      client.unary(ClientSpec::EchoRequest.new(payload: Bytes.new(50)))
      error = GRPCSpec.expect_status(Code::ResourceExhausted) { client.unary(ClientSpec::EchoRequest.new(payload: Bytes.new(200))) }
      error.status.message.should contain "Sent message larger than max"
      call = client.with_options(max_send_message_size: 1_000).client_stream
      call << ClientSpec::EchoRequest.new(payload: Bytes.new(500))
      call.close_and_receive.count.should eq 1
    end
  end

  it "lets interceptors set wait_for_ready and call credentials" do
    port = ClientSpec.free_port
    channel = GRPC::Channel.new("127.0.0.1:#{port}", backoff: ClientSpec::FAST_BACKOFF)
    client = ClientSpec::Client.new(channel)
    seen = [] of Bool?
    client.intercept do |info, continuation|
      seen << info.wait_for_ready
      info.wait_for_ready = true if info.metadata.has_key?("x-wait")
      info.call_credentials = GRPC::CallCredentials.bearer("from-interceptor", allow_insecure: true)
      continuation.call
    end
    server = nil
    GRPCSpec.within do
      GRPCSpec.expect_status(Code::Unavailable) { client.unary(ClientSpec::EchoRequest.new) }
      waiting = GRPCSpec.async { client.unary(ClientSpec::EchoRequest.new, metadata: {"x-wait" => "1"}) }
      sleep 50.milliseconds
      server = ClientSpec::TestServer.new(port: port)
      response = GRPCSpec.await(waiting).as(ClientSpec::EchoResponse)
      String.new(response.metadata["authorization"]).should eq "Bearer from-interceptor"
      seen.should eq [nil, nil]
    end
    channel.shutdown
    server.try &.close
  end

  it "creates clients with channel options from a target" do
    server = ClientSpec::TestServer.new
    config = %({"methodConfig": [{"name": [{}], "timeout": "4s"}]})
    client = ClientSpec::Client.new(server.address, credentials: GRPC::ChannelCredentials.insecure, service_config: config)
    begin
      GRPCSpec.within { client.unary(ClientSpec::EchoRequest.new).timeout_ms.should be_close(4000, 400) }
    ensure
      client.channel.shutdown
      server.close
    end
  end

  it "supports the legacy ClientCall.start signature and reports attempts" do
    with_server do |_, channel|
      call = GRPC::ClientCall.start(channel, ClientSpec::UNARY, GRPC::Metadata.new, nil, nil, 1_000_000)
      call.send_message(ClientSpec::EchoRequest.new(message: "raw"), end_stream: true)
      call.receive_message(ClientSpec::EchoResponse).not_nil!.message.should eq "raw"
      call.status.ok?.should be_true
      call.attempts.should eq 1
      channel.retry_buffer_used.should eq 0
    end
  end
end
