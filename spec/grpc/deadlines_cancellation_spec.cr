require "./grpc_helper"

include GRPCSpec

private def elapsed(&) : Time::Span
  start = Time.instant
  yield
  Time.instant - start
end

# The handler observed the cancellation of a call whose deadline passed. The
# server's own deadline timer and the client's RST_STREAM race, so the
# cancellation code may be either.
private def wait_deadline_observed(events : GRPCSpec::Events, method : String) : Nil
  events.wait_for { |e| e.in?("on_cancel #{method} DeadlineExceeded", "on_cancel #{method} Cancelled") }
  events.wait_for(&.starts_with?("cancelled #{method} "))
end

describe "GRPC deadlines" do
  it "fails unary calls with DEADLINE_EXCEEDED and the server observes it" do
    GRPCSpec.with_server do |h|
      time = elapsed do
        error = GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) do
          h.client.unary(EchoRequest.new(sleep_ms: 5_000), deadline: 100.milliseconds)
        end
        error.status.message.should eq "Deadline exceeded"
      end
      time.should be < 2.seconds
      wait_deadline_observed(h.events, "Unary")
    end
  end

  it "does not affect calls that finish in time" do
    GRPCSpec.with_server do |h|
      h.client.unary(EchoRequest.new(sleep_ms: 10), deadline: 5.seconds).message.should eq ""
      # The deadline timers must not fire for completed calls.
      sleep 50.milliseconds
      h.events.to_a.any?(&.starts_with?("on_cancel")).should be_false
    end
  end

  it "interrupts a server stream that is being received" do
    GRPCSpec.with_server do |h|
      call = h.client.server_stream(EchoRequest.new(count: 1_000, sleep_ms: 20), deadline: 300.milliseconds)
      call.receive?.should_not be_nil
      GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) { loop { call.receive? || break } }
      call.status.code.should eq GRPC::StatusCode::DeadlineExceeded
      h.events.wait_for { |e| e.in?("on_cancel ServerStream DeadlineExceeded", "on_cancel ServerStream Cancelled") }
    end
  end

  it "interrupts a client stream waiting for its response" do
    GRPCSpec.with_server do |h|
      call = h.client.client_stream(deadline: 200.milliseconds)
      call << EchoRequest.new(sleep_ms: 5_000)
      GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) { call.close_and_receive }
      wait_deadline_observed(h.events, "ClientStream")
    end
  end

  it "makes sends after the deadline fail with DEADLINE_EXCEEDED" do
    GRPCSpec.with_server do |h|
      call = h.client.bidi(deadline: 100.milliseconds)
      call << EchoRequest.new(message: "in time")
      call.receive?.not_nil!.message.should eq "in time"
      h.events.wait_for { |e| e.in?("on_cancel Bidi DeadlineExceeded", "on_cancel Bidi Cancelled") }
      GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) { call << EchoRequest.new }
      GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) { call.receive? }
    end
  end

  it "is honoured while waiting for a stream slot (MAX_CONCURRENT_STREAMS)" do
    server = GRPC::Server.new(max_concurrent_streams: 1_u32)
    GRPCSpec.with_server(server: server) do |h|
      long = GRPCSpec.async { h.client.unary(EchoRequest.new(message: "long", sleep_ms: 1_000)).message }
      h.events.wait_for("start Unary")
      time = elapsed do
        GRPCSpec.expect_status(GRPC::StatusCode::DeadlineExceeded) do
          h.client.unary(EchoRequest.new(message: "queued"), deadline: 100.milliseconds)
        end
      end
      time.should be < 800.milliseconds
      GRPCSpec.await(long).should eq "long"
      # The abandoned stream does not hold on to the only slot.
      h.client.unary(EchoRequest.new(message: "next"), deadline: 2.seconds).message.should eq "next"
    end
  end

  it "exposes the remaining time to the handler" do
    GRPCSpec.with_server do |h|
      remaining = h.client.unary(EchoRequest.new, deadline: 2.seconds).timeout_ms
      remaining.should be > 1_000
      remaining.should be <= 2_000
    end
  end

  it "is enforced by the server with a DEADLINE_EXCEEDED status even if the client ignores it" do
    GRPCSpec.with_server do |h|
      http2 = HTTP2::Client.new("127.0.0.1", h.address.split(':').last.to_i)
      begin
        stream = http2.open_stream(deadline_fields(h, "/grpc_spec.TestService/Unary"))
        stream.send_data(GRPC::Framing.encode(EchoRequest.new(sleep_ms: 5_000).to_protobuf), end_stream: true)
        time = elapsed { stream.wait_closed(5.seconds).should be_true }
        time.should be < 2.seconds
        stream.error.should be_nil
        # Trailers-only response.
        headers = stream.headers
        headers.should contain({"grpc-status", "4"})
        headers.should contain({"grpc-message", "Deadline exceeded"})
        # Only the server's deadline timer cancelled this call.
        h.events.wait_for("on_cancel Unary DeadlineExceeded")
        h.events.wait_for("cancelled Unary DeadlineExceeded deadline_exceeded=true")
      ensure
        http2.close
      end
    end
  end

  it "sends the status after earlier messages and stops a client that is still sending" do
    GRPCSpec.with_server do |h|
      http2 = HTTP2::Client.new("127.0.0.1", h.address.split(':').last.to_i)
      begin
        stream = http2.open_stream(deadline_fields(h, "/grpc_spec.TestService/Bidi"))
        stream.send_data(GRPC::Framing.encode(EchoRequest.new(message: "first").to_protobuf))
        stream.send_data(GRPC::Framing.encode(EchoRequest.new(sleep_ms: 5_000).to_protobuf))
        message = GRPC::Framing.read(stream.body, nil, 1000).not_nil!
        EchoResponse.from_protobuf(message).message.should eq "first"
        stream.wait_closed(5.seconds).should be_true
        stream.trailers.not_nil!.should contain({"grpc-status", "4"})
        error = stream.error.should be_a(HTTP2::StreamResetError)
        error.code.should eq HTTP2::ErrorCode::NO_ERROR
        h.events.wait_for("on_cancel Bidi DeadlineExceeded")
      ensure
        http2.close
      end
    end
  end

  it "resets the stream when the response is blocked on flow control at the deadline" do
    GRPCSpec.with_server do |h|
      http2 = HTTP2::Client.new("127.0.0.1", h.address.split(':').last.to_i)
      begin
        stream = http2.open_stream(deadline_fields(h, "/grpc_spec.TestService/ServerStream"))
        # Never read the response: the server blocks once the window is full.
        stream.send_data(GRPC::Framing.encode(EchoRequest.new(count: 1_000, response_size: 100_000).to_protobuf), end_stream: true)
        time = elapsed { stream.wait_closed(5.seconds).should be_true }
        time.should be < 3.seconds
        error = stream.error.should be_a(HTTP2::StreamResetError)
        error.code.should eq HTTP2::ErrorCode::CANCEL
        h.events.wait_for("on_cancel ServerStream DeadlineExceeded")
      ensure
        http2.close
      end
    end
  end
end

private def deadline_fields(h, path) : Array({String, String})
  [
    {":method", "POST"}, {":scheme", "http"}, {":path", path},
    {":authority", h.address}, {"content-type", "application/grpc"}, {"te", "trailers"},
    {"grpc-timeout", "100m"},
  ]
end

describe "GRPC cancellation" do
  it "cancels a unary call from another fiber" do
    GRPCSpec.with_server do |h|
      call = h.client.unary_call(EchoRequest.new(sleep_ms: 5_000))
      h.events.wait_for("start Unary")
      result = GRPCSpec.async { call.response }
      call.cancel
      error = GRPCSpec.await(result).should be_a(GRPC::Error)
      error.code.should eq GRPC::StatusCode::Cancelled
      h.events.wait_for("on_cancel Unary Cancelled")
      h.events.wait_for("cancelled Unary Cancelled deadline_exceeded=false")
    end
  end

  it "cancels a server streaming call after the first response" do
    GRPCSpec.with_server do |h|
      call = h.client.server_stream(EchoRequest.new(count: 1_000, sleep_ms: 10))
      call.receive?.not_nil!.index.should eq 0
      call.cancel
      error = GRPCSpec.expect_status(GRPC::StatusCode::Cancelled) { call.receive? }
      error.status.message.should eq "Call cancelled by client"
      call.status.code.should eq GRPC::StatusCode::Cancelled
      h.events.wait_for("on_cancel ServerStream Cancelled")
      h.events.includes?("server_stream done ").should be_false
    end
  end

  it "unblocks a server stuck on flow control when the client cancels" do
    GRPCSpec.with_server do |h|
      call = h.client.server_stream(EchoRequest.new(count: 1_000, response_size: 100_000))
      call.receive?.not_nil!.payload.size.should eq 100_000
      # Let the server fill the flow control windows and block.
      sleep 50.milliseconds
      call.cancel
      h.events.wait_for("on_cancel ServerStream Cancelled")
      h.client.ping(Empty.new).should eq Empty.new
    end
  end

  it "cancels a client streaming call" do
    GRPCSpec.with_server do |h|
      call = h.client.client_stream
      call << EchoRequest.new(message: "one")
      h.events.wait_for("start ClientStream")
      call.cancel
      GRPCSpec.expect_status(GRPC::StatusCode::Cancelled) { call << EchoRequest.new }
      GRPCSpec.expect_status(GRPC::StatusCode::Cancelled) { call.close_and_receive }
      h.events.wait_for("on_cancel ClientStream Cancelled")
      h.events.includes?("client_stream done").should be_false
    end
  end

  it "cancels a bidi call while another fiber is blocked receiving" do
    GRPCSpec.with_server do |h|
      call = h.client.bidi
      call << EchoRequest.new(message: "first")
      call.receive?.not_nil!.message.should eq "first"
      receiver = GRPCSpec.async { call.receive? }
      h.events.wait_for("start Bidi")
      Fiber.yield
      call.cancel
      error = GRPCSpec.await(receiver).should be_a(GRPC::Error)
      error.code.should eq GRPC::StatusCode::Cancelled
      GRPCSpec.expect_status(GRPC::StatusCode::Cancelled) { call << EchoRequest.new }
      h.events.wait_for("on_cancel Bidi Cancelled")
      h.events.includes?("bidi done").should be_false
    end
  end

  it "cancels before anything was received" do
    GRPCSpec.with_server do |h|
      call = h.client.bidi
      call.cancel
      GRPCSpec.expect_status(GRPC::StatusCode::Cancelled) { call.receive? }
      call.status.code.should eq GRPC::StatusCode::Cancelled
    end
  end

  it "is a no-op once the call completed" do
    GRPCSpec.with_server do |h|
      call = h.client.unary_call(EchoRequest.new(message: "done"))
      call.response.message.should eq "done"
      call.cancel
      call.status.ok?.should be_true
      call.response.message.should eq "done"
    end
  end
end

describe GRPC::ServerContext do
  it "parses the method path" do
    context = GRPC::ServerContext.new("/pkg.Service/Method")
    context.service_name.should eq "pkg.Service"
    context.method_name.should eq "Method"
    context.time_remaining.should be_nil
    context.deadline_exceeded?.should be_false
  end

  it "tracks the deadline" do
    context = GRPC::ServerContext.new("/s/m", timeout: 1.millisecond)
    context.time_remaining.not_nil!.should be <= 1.millisecond
    sleep 5.milliseconds
    context.deadline_exceeded?.should be_true
    context.time_remaining.not_nil!.should be < Time::Span.zero
  end
end
