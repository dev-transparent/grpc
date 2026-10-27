require "./grpc_helper"

include GRPCSpec

# A service whose handlers raise in various ways.
class RaisingService < GrpcSpec::TestService::Service
  def unary(request, context)
    case request.message
    when "details"
      raise GRPC::Error.new(GRPC::StatusCode::InvalidArgument, "with details", Bytes[0, 1, 2, 0xff],
        GRPC::Metadata{"x-error-info" => "info", "x-error-bin" => String.new(Bytes[0xde, 0xad])})
    when "keyerror"
      {"a" => 1}["missing"]
      EchoResponse.new
    when "no message"
      raise ArgumentError.new
    else
      raise GRPC::Error.new(:not_found)
    end
  end

  def server_stream(request, responses, context)
    responses << EchoResponse.new(index: 0)
    raise "server stream exploded"
  end

  def client_stream(requests, context)
    raise IndexError.new("client stream exploded")
  end

  def bidi(requests, responses, context)
    requests.each do |request|
      raise "bidi exploded" if request.message == "explode"
      responses << EchoResponse.new(message: request.message)
    end
  end

  def ping(request, context)
    Empty.new
  end
end

describe "GRPC error handling" do
  it "propagates every status code with its message" do
    GRPCSpec.with_server do |h|
      GRPC::StatusCode.values.each do |code|
        next if code.ok?
        message = "failed with #{code} ☺ 100%\n"
        error = GRPCSpec.expect_status(code) do
          h.client.unary(EchoRequest.new(status_code: code.value, status_message: message))
        end
        error.status.message.should eq message
        error.message.should eq "#{code}: #{message}"
      end
    end
  end

  it "propagates trailing metadata and status details" do
    GRPCSpec.with_server do |h|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Unknown) do
        h.client.unary(EchoRequest.new(status_code: 2, status_message: "", trailers: {"x-trailer" => "value"}))
      end
      error.metadata["x-trailer"].should eq "value"
      error.status.message.should eq ""
    end
  end

  describe "with a raising service" do
    it "sends status details and error metadata as trailers" do
      with_raising_server do |client|
        error = GRPCSpec.expect_status(GRPC::StatusCode::InvalidArgument) { client.unary(EchoRequest.new(message: "details")) }
        error.status.message.should eq "with details"
        error.details.should eq Bytes[0, 1, 2, 0xff]
        error.metadata["x-error-info"].should eq "info"
        error.metadata["x-error-bin"].to_slice.should eq Bytes[0xde, 0xad]
        error.metadata.has_key?("grpc-status-details-bin").should be_false
      end
    end

    it "maps errors without a message" do
      with_raising_server do |client|
        error = GRPCSpec.expect_status(GRPC::StatusCode::NotFound) { client.unary(EchoRequest.new(message: "plain")) }
        error.status.message.should eq ""
        error.details.should be_nil
      end
    end

    it "maps unhandled exceptions to UNKNOWN in every call kind" do
      with_raising_server do |client|
        error = GRPCSpec.expect_status(GRPC::StatusCode::Unknown) { client.unary(EchoRequest.new(message: "keyerror")) }
        error.status.message.should contain "missing"
        error = GRPCSpec.expect_status(GRPC::StatusCode::Unknown) { client.unary(EchoRequest.new(message: "no message")) }
        error.status.message.should_not be_empty

        call = client.server_stream(EchoRequest.new)
        call.receive?.not_nil!.index.should eq 0
        error = GRPCSpec.expect_status(GRPC::StatusCode::Unknown) { call.receive? }
        error.status.message.should eq "server stream exploded"

        error = GRPCSpec.expect_status(GRPC::StatusCode::Unknown) do
          client.client_stream { |c| c << EchoRequest.new }
        end
        error.status.message.should eq "client stream exploded"

        call = client.bidi
        call << EchoRequest.new(message: "fine")
        call.receive?.not_nil!.message.should eq "fine"
        call << EchoRequest.new(message: "explode")
        error = GRPCSpec.expect_status(GRPC::StatusCode::Unknown) { call.to_a }
        error.status.message.should eq "bidi exploded"
      end
    end

    it "keeps serving after handler failures" do
      with_raising_server do |client|
        5.times do
          GRPCSpec.expect_status(GRPC::StatusCode::Unknown) { client.unary(EchoRequest.new(message: "keyerror")) }
        end
        client.ping(Empty.new).should eq Empty.new
      end
    end
  end

  it "maps raised exceptions from the test service to UNKNOWN" do
    GRPCSpec.with_server do |h|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Unknown) { h.client.unary(EchoRequest.new(message: "x", raise_exception: true)) }
      error.status.message.should eq "boom: x"
    end
  end

  describe "unimplemented" do
    it "returns UNIMPLEMENTED for an unknown service" do
      GRPCSpec.with_server do |h|
        client = GrpcSpec::MissingService::Client.new(h.channel)
        error = GRPCSpec.expect_status(GRPC::StatusCode::Unimplemented) { client.missing(Empty.new) }
        error.status.message.should contain "/grpc_spec.MissingService/Missing"
      end
    end

    it "returns UNIMPLEMENTED for an unknown method of a known service" do
      GRPCSpec.with_server do |h|
        GRPCSpec.expect_status(GRPC::StatusCode::Unimplemented) do
          h.client.call_unary("/grpc_spec.TestService/DoesNotExist", Empty.new, Empty)
        end
        call = h.client.call_server_streaming("/grpc_spec.TestService/Nope", Empty.new, Empty)
        GRPCSpec.expect_status(GRPC::StatusCode::Unimplemented) { call.to_a }
        stream = h.client.call_client_streaming("/grpc_spec.TestService/Nope", Empty, Empty)
        GRPCSpec.expect_status(GRPC::StatusCode::Unimplemented) { stream.close_and_receive }
        bidi = h.client.call_bidi_streaming("/nope/Nope", Empty, Empty)
        bidi.close_send rescue nil
        GRPCSpec.expect_status(GRPC::StatusCode::Unimplemented) { bidi.receive? }
      end
    end
  end

  describe "message size limits" do
    it "rejects requests larger than the server's max receive size" do
      server = GRPC::Server.new(max_receive_message_size: 1_000)
      GRPCSpec.with_server(server: server) do |h|
        h.client.unary(EchoRequest.new(payload: Bytes.new(900))).should be_a(EchoResponse)
        error = GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
          h.client.unary(EchoRequest.new(payload: Bytes.new(2_000)))
        end
        error.status.message.should contain "larger than max"
        GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
          h.client.client_stream { |c| c << EchoRequest.new(payload: Bytes.new(10)) << EchoRequest.new(payload: Bytes.new(5_000)) }
        end
        h.client.ping(Empty.new).should eq Empty.new
      end
    end

    it "rejects compressed requests that decompress beyond the server's max receive size" do
      server = GRPC::Server.new(max_receive_message_size: 10_000)
      GRPCSpec.with_server(server: server) do |h|
        client = h.new_client(compression: "gzip")
        GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
          client.unary(EchoRequest.new(payload: Bytes.new(1_000_000)))
        end
      end
    end

    it "rejects responses larger than the client's max receive size" do
      GRPCSpec.with_server do |h|
        client = h.new_client(max_receive_message_size: 1_000)
        client.unary(EchoRequest.new(response_size: 500)).payload.size.should eq 500
        error = GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
          client.unary(EchoRequest.new(response_size: 5_000))
        end
        error.status.message.should contain "larger than max"

        call = client.server_stream(EchoRequest.new(count: 1000, sleep_ms: 5, response_size: 5_000))
        GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) { call.to_a }
        call.status.code.should eq GRPC::StatusCode::ResourceExhausted
        h.events.wait_for { |e| e.starts_with?("on_cancel ServerStream") }

        # Compressed responses are limited by their decompressed size.
        GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
          client.unary(EchoRequest.new(response_size: 100_000, compression: "gzip"))
        end
        client.ping(Empty.new).should eq Empty.new
      end
    end

    it "rejects responses larger than the server's max send size" do
      server = GRPC::Server.new(max_send_message_size: 1_000)
      GRPCSpec.with_server(server: server) do |h|
        h.client.unary(EchoRequest.new(response_size: 100)).payload.size.should eq 100
        error = GRPCSpec.expect_status(GRPC::StatusCode::ResourceExhausted) do
          h.client.unary(EchoRequest.new(response_size: 5_000))
        end
        error.status.message.should contain "Response message larger than max"
      end
    end
  end

  describe "client streaming finished early by the server" do
    it "reports the server's error to a client that is still sending" do
      GRPCSpec.with_server do |h|
        call = h.client.client_stream
        call << EchoRequest.new(message: "ok")
        call << EchoRequest.new(status_code: 7, status_message: "denied", trailers: {"x-why" => "because"})
        h.events.wait_for { |e| e.starts_with?("start ClientStream") }
        # Keep sending until the failure is observed; the server stopped
        # reading after the second message.
        error = GRPCSpec.expect_status(GRPC::StatusCode::PermissionDenied) do
          1000.times { call << EchoRequest.new(payload: Bytes.new(10_000)) }
          call.close_and_receive
        end
        error.status.message.should eq "denied"
        error.metadata["x-why"].should eq "because"
        GRPCSpec.expect_status(GRPC::StatusCode::PermissionDenied) { call.close_and_receive }
        call.status.code.should eq GRPC::StatusCode::PermissionDenied
      end
    end

    it "reports the error from the generated block form" do
      GRPCSpec.with_server do |h|
        error = GRPCSpec.expect_status(GRPC::StatusCode::OutOfRange) do
          h.client.client_stream do |call|
            call << EchoRequest.new(status_code: 11, status_message: "too far")
            200.times { call << EchoRequest.new(payload: Bytes.new(50_000)) }
          end
        end
        error.status.message.should eq "too far"
      end
    end

    it "returns an early successful response and discards further messages" do
      early = EarlyResponseService.new
      GRPCSpec.with_server(early) do |h|
        call = h.client.client_stream
        call << EchoRequest.new(message: "first")
        h.events.wait_for("early done")
        # The server reset the request side with NO_ERROR after responding.
        call.call.stream.wait_closed(5.seconds).should be_true
        50.times { call << EchoRequest.new(payload: Bytes.new(10_000)) }
        call.close_and_receive.messages.should eq ["first"]
      end
    end
  end
end

class EarlyResponseService < TestServiceImpl
  def client_stream(requests, context)
    first = requests.receive?.not_nil!
    events << "early done"
    Summary.new(count: 1, messages: [first.message])
  end
end

private def with_raising_server(&block : Client ->) : Nil
  server = GRPC::Server.new
  server.handle(RaisingService.new)
  address = server.bind_tcp("127.0.0.1", 0)
  server.start
  channel = GRPC::Channel.new("127.0.0.1:#{address.port}")
  begin
    GRPCSpec.within { block.call(Client.new(channel)) }
  ensure
    channel.close
    server.close(1.second)
  end
end
