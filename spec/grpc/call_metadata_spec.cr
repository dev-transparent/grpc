require "./grpc_helper"

include GRPCSpec

ALL_BYTES = String.new(Bytes.new(256) { |i| i.to_u8 })

# Sends response headers before the first message and waits for the client
# to confirm it received them.
class HeadersFirstService < TestServiceImpl
  getter release = ::Channel(Nil).new(1)

  def server_stream(request, responses, context)
    context.response_metadata["x-early"] = "yes"
    context.send_response_metadata
    select
    when release.receive
    when timeout(5.seconds)
      raise GRPC::Error.new(:deadline_exceeded, "client never confirmed headers")
    end
    responses << EchoResponse.new(message: "after headers")
  end
end

describe "GRPC metadata end-to-end" do
  it "delivers text, binary and multi-valued request metadata to the server" do
    GRPCSpec.with_server do |h|
      metadata = GRPC::Metadata.new
      metadata.add("X-Text", "hello world")
      metadata.add("x-data-bin", ALL_BYTES)
      metadata.add("x-empty", "")
      response = h.client.unary(EchoRequest.new, metadata: metadata)
      response.metadata["x-text"].should eq "hello world".to_slice
      response.metadata["x-data-bin"].should eq ALL_BYTES.to_slice
      response.metadata["x-empty"].should eq Bytes.empty
    end
  end

  it "hides protocol headers from the server's metadata" do
    GRPCSpec.with_server do |h|
      keys = h.client.unary(EchoRequest.new, deadline: 5.seconds).metadata.keys
      ["content-type", "te", "user-agent", "grpc-timeout", "grpc-accept-encoding", "grpc-encoding", ":path", ":authority"].each do |key|
        keys.should_not contain key
      end
      keys = h.new_client(compression: "gzip").unary(EchoRequest.new).metadata.keys
      keys.should_not contain "grpc-encoding"
    end
  end

  it "echoes headers and trailers, including binary and multi-valued ones, in all call kinds" do
    GRPCSpec.with_server do |h|
      metadata = GRPC::Metadata.new
      metadata.add("x-echo-initial", "first")
      metadata.add("x-echo-initial", "second")
      metadata.add("x-echo-initial-bin", ALL_BYTES)
      metadata.add("x-echo-trailing-bin", Bytes[0xab, 0xab, 0xab])
      metadata.add("x-echo-trailing", "trailer")

      check = ->(headers : GRPC::Metadata, trailers : GRPC::Metadata) do
        headers.get_all("x-echo-initial").should eq ["first", "second"]
        headers["x-echo-initial-bin"].should eq ALL_BYTES
        trailers["x-echo-trailing-bin"].to_slice.should eq Bytes[0xab, 0xab, 0xab]
        trailers["x-echo-trailing"].should eq "trailer"
        headers.has_key?("x-echo-trailing").should be_false
        trailers.has_key?("x-echo-initial").should be_false
        nil
      end

      unary = h.client.unary_call(EchoRequest.new, metadata: metadata)
      unary.response
      check.call(unary.headers, unary.trailers)

      stream = h.client.server_stream(EchoRequest.new(count: 2), metadata: metadata)
      stream.to_a.size.should eq 2
      check.call(stream.headers, stream.trailers)

      client_stream = h.client.client_stream(metadata: metadata)
      client_stream << EchoRequest.new
      client_stream.close_and_receive
      check.call(client_stream.headers, client_stream.trailers)

      bidi = h.client.bidi(metadata: metadata)
      bidi << EchoRequest.new
      bidi.close_send
      bidi.to_a.size.should eq 1
      check.call(bidi.headers, bidi.trailers)
    end
  end

  it "sends response metadata set by the handler" do
    GRPCSpec.with_server do |h|
      call = h.client.unary_call(EchoRequest.new(headers: {"x-h-bin" => "\u{1}\u{2}"}, trailers: {"x-t-bin" => "\u{3}"}))
      call.response
      call.headers["x-h-bin"].should eq "\u{1}\u{2}"
      call.trailers["x-t-bin"].should eq "\u{3}"
    end
  end

  it "delivers response headers before the first message with send_response_metadata" do
    service = HeadersFirstService.new
    GRPCSpec.with_server(service) do |h|
      call = h.client.server_stream(EchoRequest.new)
      call.headers["x-early"].should eq "yes"
      service.release.send(nil)
      call.to_a.map(&.message).should eq ["after headers"]
    end
  end

  it "carries large metadata values" do
    GRPCSpec.with_server do |h|
      value = "v" * 8_000
      binary = Bytes.new(6_000) { |i| (i % 256).to_u8 }
      metadata = GRPC::Metadata{"x-echo-initial" => value}
      metadata["x-echo-trailing-bin"] = binary
      call = h.client.unary_call(EchoRequest.new, metadata: metadata)
      call.response
      call.headers["x-echo-initial"].should eq value
      call.trailers["x-echo-trailing-bin"].to_slice.should eq binary
    end
  end

  it "validates metadata on the client before sending" do
    GRPCSpec.with_server do |h|
      expect_raises(GRPC::Metadata::InvalidError) { h.client.unary(EchoRequest.new, metadata: {"bad key" => "v"}) }
      expect_raises(GRPC::Metadata::InvalidError) { h.client.unary(EchoRequest.new, metadata: {"x-ok" => "bad\nvalue"}) }
      expect_raises(GRPC::Metadata::InvalidError) { h.client.unary(EchoRequest.new, metadata: {"grpc-timeout" => "1S"}) }
    end
  end
end
