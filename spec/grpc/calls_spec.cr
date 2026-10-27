require "./grpc_helper"

include GRPCSpec

describe "GRPC calls end-to-end" do
  describe "unary" do
    it "returns the response" do
      GRPCSpec.with_server do |h|
        response = h.client.unary(EchoRequest.new(message: "hello", response_size: 10))
        response.message.should eq "hello"
        response.payload.should eq Bytes.new(10)
        response.method_path.should eq "/grpc_spec.TestService/Unary"
        response.authority.should eq h.address
        response.peer.should start_with "127.0.0.1:"
        response.timeout_ms.should eq -1
        response.request_compressed.should be_false
      end
    end

    it "handles empty messages" do
      GRPCSpec.with_server do |h|
        h.client.ping(Empty.new).should eq Empty.new
        h.client.unary(EchoRequest.new).should eq h.client.unary(EchoRequest.new)
      end
    end

    it "exposes headers, trailers and status through the _call variant" do
      GRPCSpec.with_server do |h|
        call = h.client.unary_call(EchoRequest.new(message: "x", headers: {"x-head" => "h"}, trailers: {"x-trail" => "t"}))
        call.headers["x-head"].should eq "h"
        call.response.message.should eq "x"
        call.response.should be(call.response) # memoized
        call.trailers["x-trail"].should eq "t"
        call.status.ok?.should be_true
        call.headers.has_key?("content-type").should be_false
        call.trailers.has_key?("grpc-status").should be_false
      end
    end

    it "exposes trailers of failed _call variants" do
      GRPCSpec.with_server do |h|
        call = h.client.unary_call(EchoRequest.new(status_code: 5, status_message: "gone", trailers: {"x-trail" => "t"}))
        error = GRPCSpec.expect_status(GRPC::StatusCode::NotFound) { call.response }
        error.metadata["x-trail"].should eq "t"
        call.status.code.should eq GRPC::StatusCode::NotFound
        call.trailers["x-trail"].should eq "t"
        call.headers.empty?.should be_true # trailers-only response
      end
    end
  end

  describe "server streaming" do
    it "streams N messages with each" do
      GRPCSpec.with_server do |h|
        received = [] of Int32
        h.client.server_stream(EchoRequest.new(message: "s", count: 5)).each do |response|
          response.message.should eq "s"
          received << response.index
        end
        received.should eq [0, 1, 2, 3, 4]
      end
    end

    it "supports to_a, receive? and status" do
      GRPCSpec.with_server do |h|
        h.client.server_stream(EchoRequest.new(count: 3)).to_a.map(&.index).should eq [0, 1, 2]

        call = h.client.server_stream(EchoRequest.new(count: 2, headers: {"x-h" => "1"}, trailers: {"x-t" => "2"}))
        call.headers["x-h"].should eq "1"
        call.receive?.not_nil!.index.should eq 0
        call.receive?.not_nil!.index.should eq 1
        call.receive?.should be_nil
        call.receive?.should be_nil
        call.status.ok?.should be_true
        call.trailers["x-t"].should eq "2"
      end
    end

    it "handles zero messages" do
      GRPCSpec.with_server do |h|
        call = h.client.server_stream(EchoRequest.new(count: 0))
        call.to_a.should be_empty
        call.status.ok?.should be_true
      end
    end

    it "is lazy as an iterator" do
      GRPCSpec.with_server do |h|
        call = h.client.server_stream(EchoRequest.new(count: 10))
        call.first(3).map(&.index).to_a.should eq [0, 1, 2]
        call.cancel
      end
    end

    it "raises the error after the messages sent before it" do
      GRPCSpec.with_server do |h|
        call = h.client.server_stream(EchoRequest.new(count: 5, fail_after: 2, status_code: 9, status_message: "stop", trailers: {"x-t" => "v"}))
        call.receive?.not_nil!.index.should eq 0
        call.receive?.not_nil!.index.should eq 1
        error = GRPCSpec.expect_status(GRPC::StatusCode::FailedPrecondition) { call.receive? }
        error.status.message.should eq "stop"
        error.metadata["x-t"].should eq "v"
        call.status.code.should eq GRPC::StatusCode::FailedPrecondition
      end
    end
  end

  describe "client streaming" do
    it "sends many messages and returns the summary" do
      GRPCSpec.with_server do |h|
        call = h.client.client_stream
        call << EchoRequest.new(message: "a", payload: Bytes.new(3))
        call.send(EchoRequest.new(message: "b", payload: Bytes.new(4)))
        summary = call.close_and_receive
        summary.count.should eq 2
        summary.total_bytes.should eq 7
        summary.messages.should eq ["a", "b"]
        call.status.ok?.should be_true
      end
    end

    it "supports the generated block form" do
      GRPCSpec.with_server do |h|
        summary = h.client.client_stream do |call|
          10.times { |i| call << EchoRequest.new(message: i.to_s) }
        end
        summary.count.should eq 10
        summary.messages.should eq (0...10).map(&.to_s)
      end
    end

    it "cancels the call when the block raises" do
      GRPCSpec.with_server do |h|
        expect_raises(Exception, "client side failure") do
          h.client.client_stream do |call|
            call << EchoRequest.new(message: "a")
            raise "client side failure"
          end
        end
        h.events.wait_for("on_cancel ClientStream Cancelled")
        h.events.includes?("client_stream done").should be_false
      end
    end

    it "handles zero messages" do
      GRPCSpec.with_server do |h|
        h.client.client_stream.close_and_receive.count.should eq 0
      end
    end

    it "exposes headers and trailers" do
      GRPCSpec.with_server do |h|
        call = h.client.client_stream
        call << EchoRequest.new(headers: {"x-h" => "1"}, trailers: {"x-t" => "2"})
        call.close_and_receive
        call.headers["x-h"].should eq "1"
        call.trailers["x-t"].should eq "2"
      end
    end
  end

  describe "bidirectional streaming" do
    it "ping-pongs messages" do
      GRPCSpec.with_server do |h|
        call = h.client.bidi
        3.times do |i|
          call.send(EchoRequest.new(message: "ping #{i}"))
          response = call.receive?.not_nil!
          response.message.should eq "ping #{i}"
          response.index.should eq i
        end
        call.close_send
        call.receive?.should be_nil
        call.status.ok?.should be_true
      end
    end

    it "sends and receives concurrently from separate fibers" do
      GRPCSpec.with_server do |h|
        call = h.client.bidi
        sender = GRPCSpec.async do
          100.times { |i| call << EchoRequest.new(message: i.to_s, count: 2) }
          call.close_send
          true
        end
        received = call.to_a
        GRPCSpec.await(sender).should eq true
        received.size.should eq 200
        received.map(&.index).should eq (0...200).to_a
        received.map(&.message).should eq (0...100).flat_map { |i| [i.to_s, i.to_s] }
      end
    end

    it "handles an immediately closed request stream" do
      GRPCSpec.with_server do |h|
        call = h.client.bidi
        call.close_send
        call.to_a.should be_empty
        call.status.ok?.should be_true
      end
    end

    it "propagates errors raised mid-stream" do
      GRPCSpec.with_server do |h|
        call = h.client.bidi
        call << EchoRequest.new(message: "ok")
        call.receive?.not_nil!.message.should eq "ok"
        call << EchoRequest.new(status_code: 10, status_message: "aborted!")
        error = GRPCSpec.expect_status(GRPC::StatusCode::Aborted) { call.receive? }
        error.status.message.should eq "aborted!"
        # Sending after the server finished with an error reports that error.
        GRPCSpec.expect_status(GRPC::StatusCode::Aborted) { call << EchoRequest.new }
      end
    end
  end

  describe "large messages" do
    it "transfers multi-megabyte requests and responses in all call kinds" do
      GRPCSpec.with_server(timeout: 30.seconds) do |h|
        big = Bytes.new(3_500_000) { |i| (i % 251).to_u8 }
        response = h.client.unary(EchoRequest.new(payload: big, response_size: 3_900_000))
        response.payload.size.should eq 3_900_000

        h.client.server_stream(EchoRequest.new(count: 3, response_size: 3_000_000)).map(&.payload.size).to_a.should eq [3_000_000] * 3

        summary = h.client.client_stream do |call|
          3.times { call << EchoRequest.new(payload: big) }
        end
        summary.total_bytes.should eq 3 * big.size

        call = h.client.bidi
        sender = GRPCSpec.async do
          2.times { call << EchoRequest.new(payload: big, response_size: 3_000_000) }
          call.close_send
          true
        end
        call.to_a.map(&.payload.size).should eq [3_000_000, 3_000_000]
        GRPCSpec.await(sender, 20.seconds)
      end
    end

    it "accepts messages up to a raised max receive size on both sides" do
      server = GRPC::Server.new(max_receive_message_size: 10_000_000)
      GRPCSpec.with_server(server: server, timeout: 30.seconds) do |h|
        client = h.new_client(max_receive_message_size: 10_000_000)
        response = client.unary(EchoRequest.new(payload: Bytes.new(6_000_000), response_size: 6_000_000))
        response.payload.size.should eq 6_000_000
      end
    end
  end

  describe "concurrency" do
    it "multiplexes many concurrent calls of all kinds over one channel" do
      GRPCSpec.with_server(timeout: 30.seconds) do |h|
        results = ::Channel(Bool | Exception).new(200)
        50.times do |i|
          spawn do
            results.send(h.client.unary(EchoRequest.new(message: "u#{i}", response_size: 1000)).message == "u#{i}")
          rescue e
            results.send(e)
          end
          spawn do
            results.send(h.client.server_stream(EchoRequest.new(count: 5)).to_a.size == 5)
          rescue e
            results.send(e)
          end
          spawn do
            summary = h.client.client_stream { |c| 3.times { c << EchoRequest.new(message: i.to_s) } }
            results.send(summary.messages == [i.to_s] * 3)
          rescue e
            results.send(e)
          end
          spawn do
            call = h.client.bidi
            call << EchoRequest.new(message: "b#{i}")
            call.close_send
            results.send(call.to_a.map(&.message) == ["b#{i}"])
          rescue e
            results.send(e)
          end
        end
        200.times do
          result = GRPCSpec.await(results, 20.seconds)
          raise result if result.is_a?(Exception)
          result.should be_true
        end
      end
    end

    it "handles more concurrent calls than max_concurrent_streams" do
      server = GRPC::Server.new(max_concurrent_streams: 4_u32)
      GRPCSpec.with_server(server: server) do |h|
        results = ::Channel(Int32 | Exception).new(20)
        20.times do |i|
          spawn do
            results.send(h.client.unary(EchoRequest.new(sleep_ms: 20, message: i.to_s)).message.to_i)
          rescue e
            results.send(e)
          end
        end
        values = Array.new(20) do
          value = GRPCSpec.await(results)
          raise value if value.is_a?(Exception)
          value
        end
        values.sort.should eq (0...20).to_a
      end
    end
  end

  describe "generated client options" do
    it "sends default metadata merged with per-call metadata" do
      GRPCSpec.with_server do |h|
        client = h.new_client(metadata: {"x-default" => "d", "x-both" => "default"})
        client.metadata["x-default"].should eq "d"
        response = client.unary(EchoRequest.new, metadata: {"x-call" => "c", "x-both" => "call"})
        response.metadata["x-default"].should eq "d".to_slice
        response.metadata["x-call"].should eq "c".to_slice
        # Both values are sent; the default comes first.
        call = client.unary_call(EchoRequest.new, metadata: GRPC::Metadata{"x-echo-initial" => "per-call"})
        call.headers["x-echo-initial"].should eq "per-call"
        client.metadata.has_key?("x-echo-initial").should be_false
      end
    end

    it "applies default_timeout unless a deadline is given" do
      GRPCSpec.with_server do |h|
        client = h.new_client(default_timeout: 3.seconds)
        timeout = client.unary(EchoRequest.new).timeout_ms
        timeout.should be > 2_000
        timeout.should be <= 3_000

        timeout = client.unary(EchoRequest.new, deadline: 30.seconds).timeout_ms
        timeout.should be > 20_000

        timeout = client.unary(EchoRequest.new, deadline: Time.utc + 60.seconds).timeout_ms
        timeout.should be > 50_000
        timeout.should be <= 60_000

        GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) do
          h.new_client(default_timeout: 50.milliseconds).unary(EchoRequest.new(sleep_ms: 2_000))
        end
      end
    end

    it "fails fast with DEADLINE_EXCEEDED for deadlines already in the past" do
      GRPCSpec.with_server do |h|
        GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) do
          h.client.unary(EchoRequest.new, deadline: Time.utc - 1.second)
        end
        GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) do
          h.client.unary(EchoRequest.new, deadline: Time::Span.zero)
        end
      end
    end

    it "can be created from a target string" do
      GRPCSpec.with_server do |h|
        client = Client.new(h.address, metadata: {"x-k" => "v"})
        begin
          client.unary(EchoRequest.new).metadata["x-k"].should eq "v".to_slice
          client.channel.target.should eq h.address
        ensure
          client.close
        end
        client = Client.new("http://#{h.address}/")
        begin
          client.ping(Empty.new).should eq Empty.new
        ensure
          client.close
        end
      end
    end

    it "rejects unsupported compression" do
      GRPCSpec.with_server do |h|
        expect_raises(ArgumentError) { h.new_client(compression: "snappy") }
        expect_raises(ArgumentError) { GRPC::Server.new(compression: "snappy") }
      end
    end
  end

  describe "transports" do
    it "works over a UNIX socket" do
      path = GRPCSpec.unused_unix_path
      server = GRPC::Server.new
      server.handle(TestServiceImpl.new)
      server.bind("unix:#{path}")
      server.start
      channel = GRPC::Channel.new("unix:#{path}")
      begin
        GRPCSpec.within do
          client = Client.new(channel)
          response = client.unary(EchoRequest.new(message: "over unix"))
          response.message.should eq "over unix"
          response.authority.should eq "localhost"
          client.server_stream(EchoRequest.new(count: 3)).to_a.size.should eq 3
          client.client_stream { |c| c << EchoRequest.new }.count.should eq 1
          call = client.bidi
          call << EchoRequest.new(message: "b")
          call.close_send
          call.to_a.map(&.message).should eq ["b"]
        end
      ensure
        channel.close
        server.close(1.second)
        File.delete?(path)
      end
    end

    it "binds with host:port strings" do
      server = GRPC::Server.new
      server.handle(TestServiceImpl.new)
      address = server.bind("127.0.0.1:0").as(Socket::IPAddress)
      server.start
      client = Client.new(GRPC::Channel.new("127.0.0.1:#{address.port}"))
      begin
        GRPCSpec.within { client.ping(Empty.new).should eq Empty.new }
      ensure
        client.close
        server.close(1.second)
      end
    end
  end
end
