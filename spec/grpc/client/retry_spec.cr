require "./client_helper"

private alias Code = GRPC::StatusCode
private alias Scripted = ClientSpec::ScriptedServer

private def retry_policy(max_attempts = 4, codes = %w(UNAVAILABLE), initial = "0.01s", max = "0.05s") : String
  %("retryPolicy": {"maxAttempts": #{max_attempts}, "initialBackoff": "#{initial}", "maxBackoff": "#{max}",
                     "backoffMultiplier": 2, "retryableStatusCodes": #{codes.to_json}})
end

private def hedging_policy(max_attempts = 3, delay = "0.1s", codes = %w(UNAVAILABLE)) : String
  %("hedgingPolicy": {"maxAttempts": #{max_attempts}, "hedgingDelay": "#{delay}", "nonFatalStatusCodes": #{codes.to_json}})
end

private def config(policy : String, throttling : String? = nil) : String
  json = %({"methodConfig": [{"name": [{"service": "grpc_spec.TestService"}], #{policy}}])
  json += %(, "retryThrottling": #{throttling}) if throttling
  json + "}"
end

private alias Handler = Proc(Int32, HTTP2::Server::Context, Nil)

private def with_scripted(service_config : String?, handler : Handler, per_rpc_buffer_size = GRPC::Channel::DEFAULT_PER_RPC_BUFFER_SIZE, enable_retries = true,
                          &block : Scripted, ClientSpec::Client, GRPC::Channel ->)
  server = Scripted.new { |index, context| handler.call(index, context) }
  channel = GRPC::Channel.new(server.address, service_config: service_config,
    per_rpc_buffer_size: per_rpc_buffer_size, enable_retries: enable_retries)
  begin
    GRPCSpec.within(15.seconds) { block.call(server, ClientSpec::Client.new(channel), channel) }
  ensure
    channel.shutdown
    server.close
  end
end

# Reads all request messages of a request.
private def read_messages(context : HTTP2::Server::Context) : Array(ClientSpec::EchoRequest)
  messages = [] of ClientSpec::EchoRequest
  while bytes = GRPC::Framing.read(context.request.body, nil, 10_000_000)
    messages << ClientSpec::EchoRequest.from_protobuf(bytes)
  end
  messages
end

private def respond(context : HTTP2::Server::Context, message : Protobuf::Message) : Nil
  stream = context.stream
  stream.send_headers([{":status", "200"}, {"content-type", "application/grpc"}])
  stream.send_data(GRPC::Framing.encode(message.to_protobuf))
  stream.send_trailers([{"grpc-status", "0"}])
end

private def request(message = "hi") : ClientSpec::EchoRequest
  ClientSpec::EchoRequest.new(message: message)
end

describe "GRPC retries (gRFC A6)" do
  it "retries until an attempt succeeds" do
    with_scripted(config(retry_policy), ->(index : Int32, context : HTTP2::Server::Context) { index < 2 ? Scripted.fail(context, Code::Unavailable) : Scripted.ok(context) }) do |server, client|
      client.unary(request).message.should eq "ok"
      server.request_count.should eq 3
      server.header_values("grpc-previous-rpc-attempts").should eq [nil, "1", "2"]
    end
  end

  it "does not retry non-retryable codes" do
    with_scripted(config(retry_policy), ->(_index : Int32, context : HTTP2::Server::Context) { Scripted.fail(context, Code::InvalidArgument) }) do |server, client|
      error = GRPCSpec.expect_status(Code::InvalidArgument) { client.unary(request) }
      error.status.message.should eq "scripted InvalidArgument"
      server.request_count.should eq 1
    end
  end

  it "stops after maxAttempts and returns the last status" do
    with_scripted(config(retry_policy(max_attempts: 3)), ->(_index : Int32, context : HTTP2::Server::Context) { Scripted.fail(context, Code::Unavailable) }) do |server, client|
      GRPCSpec.expect_status(Code::Unavailable) { client.unary(request) }
      server.request_count.should eq 3
    end
  end

  it "honours server pushback" do
    with_scripted(config(retry_policy), ->(index : Int32, context : HTTP2::Server::Context) { index == 0 ? Scripted.fail(context, Code::Unavailable, [{"grpc-retry-pushback-ms", "300"}]) : Scripted.ok(context) }) do |server, client|
      started = Time.instant
      client.unary(request).message.should eq "ok"
      (Time.instant - started).should be >= 290.milliseconds
      server.request_count.should eq 2
    end
  end

  it "does not retry when pushback is negative or malformed" do
    {"-1", "abc", "01"}.each do |value|
      with_scripted(config(retry_policy), ->(_index : Int32, context : HTTP2::Server::Context) { Scripted.fail(context, Code::Unavailable, [{"grpc-retry-pushback-ms", value}]) }) do |server, client|
        GRPCSpec.expect_status(Code::Unavailable) { client.unary(request) }
        server.request_count.should eq 1
      end
    end
  end

  it "does not retry once response headers were received" do
    with_scripted(config(retry_policy), ->(_index : Int32, context : HTTP2::Server::Context) do
      read_messages(context)
      context.stream.send_headers([{":status", "200"}, {"content-type", "application/grpc"}])
      context.stream.send_trailers([{"grpc-status", "14"}])
    end) do |server, client|
      GRPCSpec.expect_status(Code::Unavailable) { client.unary(request) }
      server.request_count.should eq 1
    end
  end

  it "retries server streaming calls before the first response" do
    with_scripted(config(retry_policy), ->(index : Int32, context : HTTP2::Server::Context) do
      return Scripted.fail(context, Code::Unavailable) if index == 0
      message = read_messages(context).first.message
      respond(context, ClientSpec::EchoResponse.new(message: "#{message}-#{index}"))
    end) do |server, client|
      client.server_stream(request("stream")).map(&.message).to_a.should eq ["stream-1"]
      server.request_count.should eq 2
    end
  end

  it "replays buffered client streaming messages" do
    with_scripted(config(retry_policy), ->(index : Int32, context : HTTP2::Server::Context) do
      messages = read_messages(context)
      return Scripted.fail(context, Code::Unavailable, read_body: false) if index == 0
      respond(context, GrpcSpec::Summary.new(count: messages.size, messages: messages.map(&.message)))
    end) do |server, client|
      summary = client.client_stream do |call|
        3.times { |i| call << request("m#{i}") }
      end
      summary.messages.should eq ["m0", "m1", "m2"]
      server.request_count.should eq 2
    end
  end

  it "retries bidi calls before commit" do
    with_scripted(config(retry_policy), ->(index : Int32, context : HTTP2::Server::Context) do
      messages = read_messages(context)
      return Scripted.fail(context, Code::Unavailable, read_body: false) if index == 0
      stream = context.stream
      stream.send_headers([{":status", "200"}, {"content-type", "application/grpc"}])
      messages.each { |m| stream.send_data(GRPC::Framing.encode(ClientSpec::EchoResponse.new(message: m.message).to_protobuf)) }
      stream.send_trailers([{"grpc-status", "0"}])
    end) do |server, client|
      call = client.bidi
      call << request("a")
      call << request("b")
      call.close_send
      call.map(&.message).to_a.should eq ["a", "b"]
      server.request_count.should eq 2
    end
  end

  it "commits (no retries) when the retry buffer overflows" do
    with_scripted(config(retry_policy), ->(_index : Int32, context : HTTP2::Server::Context) do
      read_messages(context)
      Scripted.fail(context, Code::Unavailable, read_body: false)
    end, per_rpc_buffer_size: 150) do |server, client, channel|
      error = GRPCSpec.expect_status(Code::Unavailable) do
        client.client_stream do |call|
          3.times { call << ClientSpec::EchoRequest.new(payload: Bytes.new(100)) }
        end
      end
      server.request_count.should eq 1
      channel.retry_buffer_used.should eq 0
    end
  end

  it "throttles retries" do
    throttling = %({"maxTokens": 3, "tokenRatio": 0.5})
    with_scripted(config(retry_policy(max_attempts: 5), throttling), ->(_index : Int32, context : HTTP2::Server::Context) { Scripted.fail(context, Code::Unavailable) }) do |server, client, channel|
      # 3 tokens: the first failure leaves 2 (> 1.5, retry), the second 1
      # (<= 1.5, no more retries).
      GRPCSpec.expect_status(Code::Unavailable) { client.unary(request) }
      server.request_count.should eq 2
      channel.retry_throttle.not_nil!.tokens.should eq 1.0
      # Still throttled: no retry at all.
      GRPCSpec.expect_status(Code::Unavailable) { client.unary(request) }
      server.request_count.should eq 3
    end
  end

  it "retries attempts failing to pick a connection" do
    port = ClientSpec.free_port
    channel = GRPC::Channel.new("127.0.0.1:#{port}", backoff: ClientSpec::FAST_BACKOFF,
      service_config: config(retry_policy(max_attempts: 3, initial: "0.2s", max: "0.2s")))
    GRPCSpec.within do
      started = Time.instant
      GRPCSpec.expect_status(Code::Unavailable) { ClientSpec::Client.new(channel).unary(request) }
      (Time.instant - started).should be >= 300.milliseconds
    end
    channel.shutdown
  end

  it "does not retry beyond the deadline" do
    with_scripted(config(retry_policy(max_attempts: 5, initial: "0.3s", max: "0.3s")), ->(_index : Int32, context : HTTP2::Server::Context) { Scripted.fail(context, Code::Unavailable) }) do |server, client|
      started = Time.instant
      GRPCSpec.expect_status(Code::Unavailable) { client.unary(request, deadline: 200.milliseconds) }
      (Time.instant - started).should be < 200.milliseconds
      server.request_count.should eq 1
    end
  end

  it "does not retry when retries are disabled" do
    with_scripted(config(retry_policy), ->(index : Int32, context : HTTP2::Server::Context) { index == 0 ? Scripted.fail(context, Code::Unavailable) : Scripted.ok(context) }, enable_retries: false) do |server, client|
      GRPCSpec.expect_status(Code::Unavailable) { client.unary(request) }
      server.request_count.should eq 1
    end
  end

  describe "transparent retries" do
    it "retries a refused stream once without a retry policy" do
      with_scripted(nil, ->(index : Int32, context : HTTP2::Server::Context) do
        return context.stream.reset(HTTP2::ErrorCode::REFUSED_STREAM) if index < 1
        return Scripted.fail(context, Code::Unavailable) if index < 1
        Scripted.ok(context)
      end) do |server, client|
        client.unary(request).message.should eq "ok"
        server.request_count.should eq 2
        server.header_values("grpc-previous-rpc-attempts").should eq [nil, "1"]
      end
    end

    it "retries only once transparently" do
      with_scripted(nil, ->(index : Int32, context : HTTP2::Server::Context) do
        return context.stream.reset(HTTP2::ErrorCode::REFUSED_STREAM) if index < 5
        return Scripted.fail(context, Code::Unavailable) if index < 5
        Scripted.ok(context)
      end) do |server, client|
        GRPCSpec.expect_status(Code::Unavailable) { client.unary(request) }
        server.request_count.should eq 2
      end
    end

    it "then applies the retry policy" do
      with_scripted(config(retry_policy(max_attempts: 2)), ->(index : Int32, context : HTTP2::Server::Context) do
        return context.stream.reset(HTTP2::ErrorCode::REFUSED_STREAM) if index < 1
        return Scripted.fail(context, Code::Unavailable) if index < 2
        Scripted.ok(context)
      end) do |server, client|
        client.unary(request).message.should eq "ok"
        # Transparent retries do not count towards maxAttempts.
        server.request_count.should eq 3
      end
    end
  end

  describe "hedging" do
    it "sends hedged attempts after hedgingDelay and uses the first response" do
      cancelled = Channel(Bool).new(1)
      with_scripted(config(hedging_policy(delay: "0.1s")), ->(index : Int32, context : HTTP2::Server::Context) do
        read_messages(context)
        return respond(context, ClientSpec::EchoResponse.new(message: "fast")) if index > 0
        deadline = Time.instant + 2.seconds
        until context.stream.reset? || Time.instant > deadline
          sleep 5.milliseconds
        end
        if context.stream.reset?
          cancelled.send(true)
        else
          respond(context, ClientSpec::EchoResponse.new(message: "slow"))
        end
      end) do |server, client|
        started = Time.instant
        client.unary(request).message.should eq "fast"
        (Time.instant - started).should be < 900.milliseconds
        server.request_count.should eq 2
        server.header_values("grpc-previous-rpc-attempts").should eq [nil, "1"]
        GRPCSpec.await(cancelled).should be_true
      end
    end

    it "sends the next hedge immediately after a non-fatal status" do
      with_scripted(config(hedging_policy(delay: "5s")), ->(index : Int32, context : HTTP2::Server::Context) { index == 0 ? Scripted.fail(context, Code::Unavailable) : Scripted.ok(context) }) do |server, client|
        started = Time.instant
        client.unary(request).message.should eq "ok"
        (Time.instant - started).should be < 2.seconds
        server.request_count.should eq 2
      end
    end

    it "fails on a fatal status" do
      with_scripted(config(hedging_policy(delay: "5s")), ->(_index : Int32, context : HTTP2::Server::Context) { Scripted.fail(context, Code::InvalidArgument) }) do |server, client|
        started = Time.instant
        GRPCSpec.expect_status(Code::InvalidArgument) { client.unary(request) }
        (Time.instant - started).should be < 2.seconds
        server.request_count.should eq 1
      end
    end

    it "returns the last failure when all attempts fail" do
      with_scripted(config(hedging_policy(max_attempts: 3, delay: "0.05s")), ->(_index : Int32, context : HTTP2::Server::Context) { Scripted.fail(context, Code::Unavailable) }) do |server, client|
        GRPCSpec.expect_status(Code::Unavailable) { client.unary(request) }
        server.request_count.should eq 3
      end
    end

    it "stops hedging on negative pushback" do
      with_scripted(config(hedging_policy(delay: "0.2s")), ->(_index : Int32, context : HTTP2::Server::Context) { Scripted.fail(context, Code::Unavailable, [{"grpc-retry-pushback-ms", "-1"}]) }) do |server, client|
        GRPCSpec.expect_status(Code::Unavailable) { client.unary(request) }
        server.request_count.should eq 1
      end
    end
  end
end

describe GRPC::RetryThrottle do
  it "keeps a token bucket" do
    throttle = GRPC::RetryThrottle.new(10, 0.5)
    throttle.allows_retry?.should be_true
    5.times { throttle.record_failure }
    throttle.tokens.should eq 5.0
    throttle.allows_retry?.should be_false # 5 <= 10 / 2
    throttle.record_success
    throttle.tokens.should eq 5.5
    throttle.allows_retry?.should be_true
    20.times { throttle.record_success }
    throttle.tokens.should eq 10.0
    20.times { throttle.record_failure }
    throttle.tokens.should eq 0.0
  end
end

describe "GRPC::ClientCall.parse_pushback" do
  it "accepts non-negative integers without leading zeros" do
    GRPC::ClientCall.parse_pushback("0").should eq 0
    GRPC::ClientCall.parse_pushback("250").should eq 250
    {"-5", "01", "abc", "", "1.5", "99999999999"}.each do |bad|
      GRPC::ClientCall.parse_pushback(bad).should eq -1
    end
  end
end

describe "GRPC client under load" do
  it "serves many concurrent calls with retries over round_robin" do
    ClientSpec.with_servers(3) do |servers|
      config = %({"loadBalancingConfig": [{"round_robin": {}}],
                  "methodConfig": [{"name": [{}], #{retry_policy}}]})
      channel = GRPC::Channel.new("ipv4:#{servers.map(&.address).join(',')}", service_config: config)
      client = ClientSpec::Client.new(channel)
      results = Channel(String | Exception).new(200)
      200.times do |i|
        spawn do
          case i % 3
          when 0 then results.send(client.unary(ClientSpec::EchoRequest.new(message: "u#{i}")).message)
          when 1 then results.send(client.server_stream(ClientSpec::EchoRequest.new(message: "s#{i}", count: 2)).to_a.last.message)
          else        results.send(client.client_stream { |c| c << ClientSpec::EchoRequest.new(message: "c#{i}") }.messages.first)
          end
        rescue e
          results.send(e)
        end
      end
      received = Array.new(200) { GRPCSpec.await(results, 15.seconds) }
      received.select(Exception).should be_empty
      received.size.should eq 200
      channel.retry_buffer_used.should eq 0
      channel.shutdown
    end
  end
end
