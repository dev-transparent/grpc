require "./grpc_helper"

include GRPCSpec

private def response_encoding(call) : String?
  call.call.stream.headers.find { |(name, _)| name == "grpc-encoding" }.try(&.[1])
end

describe "GRPC compression" do
  {"gzip", "deflate"}.each do |algorithm|
    it "compresses requests with #{algorithm} in all call kinds" do
      GRPCSpec.with_server do |h|
        client = h.new_client(compression: algorithm)
        client.compression.should eq algorithm
        response = client.unary(EchoRequest.new(payload: Bytes.new(100_000), message: "zipped"))
        response.request_compressed.should be_true
        response.message.should eq "zipped"

        client.server_stream(EchoRequest.new(count: 2)).to_a.all?(&.request_compressed).should be_true

        summary = client.client_stream { |c| 3.times { c << EchoRequest.new(payload: Bytes.new(50_000)) } }
        summary.any_compressed.should be_true
        summary.total_bytes.should eq 150_000

        call = client.bidi
        call << EchoRequest.new(message: "b")
        call.close_send
        call.to_a.map(&.request_compressed).should eq [true]
      end
    end

    it "compresses responses with #{algorithm} when the handler sets context.compression" do
      GRPCSpec.with_server do |h|
        call = h.client.unary_call(EchoRequest.new(compression: algorithm, response_size: 200_000))
        call.response.payload.should eq Bytes.new(200_000)
        response_encoding(call).should eq algorithm

        stream = h.client.server_stream(EchoRequest.new(count: 3, response_size: 50_000, compression: algorithm))
        stream.to_a.map(&.payload.size).should eq [50_000] * 3
        response_encoding(stream).should eq algorithm
      end
    end
  end

  it "does not compress by default" do
    GRPCSpec.with_server do |h|
      call = h.client.unary_call(EchoRequest.new)
      call.response.request_compressed.should be_false
      response_encoding(call).should be_nil
      h.new_client(compression: "identity").unary(EchoRequest.new).request_compressed.should be_false
    end
  end

  it "uses the server's default compression and lets handlers override it" do
    server = GRPC::Server.new(compression: "gzip")
    server.compression.should eq "gzip"
    GRPCSpec.with_server(server: server) do |h|
      call = h.client.unary_call(EchoRequest.new(response_size: 10_000))
      call.response.payload.size.should eq 10_000
      response_encoding(call).should eq "gzip"

      call = h.client.unary_call(EchoRequest.new(response_size: 10_000, compression: "identity"))
      call.response.payload.size.should eq 10_000
      response_encoding(call).should be_nil
    end
  end

  it "compresses in both directions at once" do
    GRPCSpec.with_server do |h|
      client = h.new_client(compression: "deflate")
      call = client.bidi
      sender = GRPCSpec.async do
        20.times { |i| call << EchoRequest.new(message: i.to_s, payload: Bytes.new(10_000), response_size: 10_000, compression: "gzip") }
        call.close_send
        true
      end
      responses = call.to_a
      GRPCSpec.await(sender)
      responses.size.should eq 20
      responses.all?(&.request_compressed).should be_true
      response_encoding(call).should eq "gzip"
    end
  end

  it "only compresses responses with algorithms the client accepts" do
    GRPCSpec.with_server do |h|
      http2 = HTTP2::Client.new("127.0.0.1", h.address.split(':').last.to_i)
      begin
        stream = http2.open_stream([
          {":method", "POST"}, {":scheme", "http"}, {":path", "/grpc_spec.TestService/Unary"},
          {":authority", h.address}, {"content-type", "application/grpc"}, {"te", "trailers"},
          {"grpc-accept-encoding", "identity"},
        ])
        stream.send_data(GRPC::Framing.encode(EchoRequest.new(compression: "gzip", response_size: 1000).to_protobuf), end_stream: true)
        headers = stream.headers
        headers.find { |(name, _)| name == "grpc-encoding" }.should be_nil
        message, compressed = GRPC::Framing.read_frame(stream.body, nil, 1_000_000).not_nil!
        compressed.should be_false
        EchoResponse.from_protobuf(message).payload.size.should eq 1000
        stream.wait_end_stream.not_nil!.should contain({"grpc-status", "0"})
      ensure
        http2.close
      end
    end
  end
end
