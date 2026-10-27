require "./grpc_helper"

include GRPCSpec

private def grpc_fields(h : GRPCSpec::Harness, path = "/grpc_spec.TestService/Unary", **overrides) : Array({String, String})
  fields = {
    ":method"      => "POST".as(String?),
    ":scheme"      => "http",
    ":path"        => path,
    ":authority"   => h.address,
    "content-type" => "application/grpc",
    "te"           => "trailers",
  }
  overrides.each { |key, value| fields[key.to_s.gsub('_', '-')] = value }
  fields.compact_map { |key, value| {key, value} unless value.nil? }
end

private def raw_client(h : GRPCSpec::Harness) : HTTP2::Client
  HTTP2::Client.new("127.0.0.1", h.address.split(':').last.to_i)
end

private def field(fields : Array({String, String}), name : String) : String?
  fields.find { |(key, _)| key == name }.try(&.[1])
end

# Sends a request with *fields* and *body*; returns the stream.
private def raw_call(h, fields, body : Bytes? = nil) : HTTP2::Stream
  http2 = raw_client(h)
  stream = http2.open_stream(fields, end_stream: body.nil?)
  stream.send_data(body, end_stream: true) if body
  stream
end

private def expect_trailers_only(stream : HTTP2::Stream, code : GRPC::StatusCode) : Array({String, String})
  headers = stream.headers
  field(headers, ":status").should eq "200"
  field(headers, "content-type").should eq "application/grpc"
  field(headers, "grpc-status").should eq code.value.to_s
  stream.wait_end_stream.should be_nil # no separate trailers
  stream.end_stream_received?.should be_true
  headers
end

describe "GRPC server protocol handling" do
  it "rejects non-POST requests with 405" do
    GRPCSpec.with_server do |h|
      response = raw_client(h).get("/grpc_spec.TestService/Unary", HTTP::Headers{"content-type" => "application/grpc"})
      response.status.should eq 405
      response.headers["grpc-status"].should eq GRPC::StatusCode::Unknown.value.to_s
      response.headers["grpc-message"].should eq "HTTP status 405"
    end
  end

  it "rejects unsupported content types with 415" do
    GRPCSpec.with_server do |h|
      ["application/json", "text/plain", "application/grpcx", nil].each do |content_type|
        stream = raw_call(h, grpc_fields(h, content_type: content_type), GRPC::Framing.encode(EchoRequest.new.to_protobuf))
        headers = stream.headers
        field(headers, ":status").should eq "415"
        field(headers, "grpc-status").should eq GRPC::StatusCode::Unknown.value.to_s
      end
    end
  end

  it "accepts application/grpc+proto and parameters" do
    GRPCSpec.with_server do |h|
      ["application/grpc+proto", "application/grpc;charset=utf-8"].each do |content_type|
        stream = raw_call(h, grpc_fields(h, content_type: content_type), GRPC::Framing.encode(EchoRequest.new(message: "ct").to_protobuf))
        field(stream.headers, ":status").should eq "200"
        message = GRPC::Framing.read(stream.body, nil, 1000).not_nil!
        EchoResponse.from_protobuf(message).message.should eq "ct"
        field(stream.wait_end_stream.not_nil!, "grpc-status").should eq "0"
      end
    end
  end

  it "tolerates a missing te header" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h, te: nil), GRPC::Framing.encode(EchoRequest.new(message: "no te").to_protobuf))
      field(stream.headers, ":status").should eq "200"
      EchoResponse.from_protobuf(GRPC::Framing.read(stream.body, nil, 1000).not_nil!).message.should eq "no te"
      field(stream.wait_end_stream.not_nil!, "grpc-status").should eq "0"
    end
  end

  it "sends a full response: headers, length-prefixed messages and trailers" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h, "/grpc_spec.TestService/ServerStream"),
        GRPC::Framing.encode(EchoRequest.new(count: 2, headers: {"x-h" => "1"}, trailers: {"x-t" => "2"}).to_protobuf))
      headers = stream.headers
      field(headers, ":status").should eq "200"
      field(headers, "content-type").should eq "application/grpc"
      field(headers, "grpc-accept-encoding").should eq "gzip,deflate,identity"
      field(headers, "x-h").should eq "1"
      field(headers, "grpc-status").should be_nil
      2.times { |i| EchoResponse.from_protobuf(GRPC::Framing.read(stream.body, nil, 1000).not_nil!).index.should eq i }
      GRPC::Framing.read(stream.body, nil, 1000).should be_nil
      trailers = stream.trailers.not_nil!
      field(trailers, "grpc-status").should eq "0"
      field(trailers, "grpc-message").should be_nil
      field(trailers, "x-t").should eq "2"
    end
  end

  it "uses trailers-only responses for errors before any message" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h),
        GRPC::Framing.encode(EchoRequest.new(status_code: 5, status_message: "not here ☺", headers: {"x-h" => "1"}, trailers: {"x-t" => "2"}).to_protobuf))
      headers = expect_trailers_only(stream, GRPC::StatusCode::NotFound)
      field(headers, "grpc-message").should eq "not here %E2%98%BA"
      field(headers, "x-h").should eq "1"
      field(headers, "x-t").should eq "2"
    end
  end

  it "uses trailers-only responses for unimplemented methods" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h, "/grpc_spec.TestService/Nope"), GRPC::Framing.encode(Bytes.empty))
      headers = expect_trailers_only(stream, GRPC::StatusCode::Unimplemented)
      field(headers, "grpc-message").not_nil!.should contain "Nope"
    end
  end

  it "rejects malformed grpc-timeout values with INTERNAL" do
    GRPCSpec.with_server do |h|
      ["1x", "-5S", "123456789S", "S"].each do |timeout|
        stream = raw_call(h, grpc_fields(h, grpc_timeout: timeout), GRPC::Framing.encode(EchoRequest.new.to_protobuf))
        headers = expect_trailers_only(stream, GRPC::StatusCode::Internal)
        GRPC::Status.decode_message(field(headers, "grpc-message").not_nil!).should contain "grpc-timeout"
      end
      h.events.to_a.should be_empty
    end
  end

  it "rejects unsupported grpc-encoding with UNIMPLEMENTED and advertises accepted encodings" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h, grpc_encoding: "snappy"), GRPC::Framing.encode(EchoRequest.new.to_protobuf))
      headers = expect_trailers_only(stream, GRPC::StatusCode::Unimplemented)
      field(headers, "grpc-accept-encoding").should eq "gzip,deflate,identity"
      h.events.to_a.should be_empty
    end
  end

  it "fails with INTERNAL for a compressed message without grpc-encoding" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h), GRPC::Framing.encode(EchoRequest.new.to_protobuf, "gzip"))
      headers = expect_trailers_only(stream, GRPC::StatusCode::Internal)
      GRPC::Status.decode_message(field(headers, "grpc-message").not_nil!).should contain "grpc-encoding"
    end
  end

  it "accepts uncompressed messages on a call with grpc-encoding" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h, grpc_encoding: "gzip"), GRPC::Framing.encode(EchoRequest.new(message: "plain").to_protobuf))
      response = EchoResponse.from_protobuf(GRPC::Framing.read(stream.body, nil, 1000).not_nil!)
      response.message.should eq "plain"
      response.request_compressed.should be_false
    end
  end

  it "fails unary calls with INTERNAL for zero or multiple request messages" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h))
      headers = expect_trailers_only(stream, GRPC::StatusCode::Internal)
      GRPC::Status.decode_message(field(headers, "grpc-message").not_nil!).should contain "received none"

      body = IO::Memory.new
      body.write(GRPC::Framing.encode(EchoRequest.new.to_protobuf))
      body.write(GRPC::Framing.encode(EchoRequest.new.to_protobuf))
      stream = raw_call(h, grpc_fields(h), body.to_slice)
      headers = expect_trailers_only(stream, GRPC::StatusCode::Internal)
      GRPC::Status.decode_message(field(headers, "grpc-message").not_nil!).should contain "several"
    end
  end

  it "fails with INTERNAL for unparseable request messages and truncated frames" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h), GRPC::Framing.encode(Bytes[0xff, 0xff, 0xff]))
      headers = expect_trailers_only(stream, GRPC::StatusCode::Internal)
      GRPC::Status.decode_message(field(headers, "grpc-message").not_nil!).should contain "parse"

      stream = raw_call(h, grpc_fields(h), Bytes[0, 0, 0, 0, 10, 1, 2])
      headers = expect_trailers_only(stream, GRPC::StatusCode::Internal)
      GRPC::Status.decode_message(field(headers, "grpc-message").not_nil!).should contain "Truncated"
    end
  end

  it "passes the grpc-timeout to the handler" do
    GRPCSpec.with_server do |h|
      stream = raw_call(h, grpc_fields(h, grpc_timeout: "3S"), GRPC::Framing.encode(EchoRequest.new.to_protobuf))
      response = EchoResponse.from_protobuf(GRPC::Framing.read(stream.body, nil, 1000).not_nil!)
      response.timeout_ms.should be > 2_000
      response.timeout_ms.should be <= 3_000
    end
  end
end

# A plain HTTP/2 server impersonating a (misbehaving) gRPC server.
private def with_fake_server(handler : HTTP2::Server::Context ->, &block : Client ->) : Nil
  server = HTTP2::Server.new(handler)
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  Fiber.yield
  client = Client.new(GRPC::Channel.new("127.0.0.1:#{address.port}"))
  begin
    GRPCSpec.within { block.call(client) }
  ensure
    client.close
    server.close(1.second)
  end
end

# Reads the request and responds with raw header, data and trailer frames.
private def respond_raw(headers : Array({String, String}), data : Array(Bytes) = [] of Bytes,
                        trailers : Array({String, String})? = nil, reset : HTTP2::ErrorCode? = nil) : HTTP2::Server::Context ->
  ->(context : HTTP2::Server::Context) do
    context.request.body.gets_to_end
    stream = context.stream
    stream.send_headers(headers, end_stream: data.empty? && trailers.nil? && reset.nil?)
    data.each_with_index do |chunk, i|
      stream.send_data(chunk, end_stream: trailers.nil? && reset.nil? && i == data.size - 1)
    end
    if code = reset
      stream.reset(code)
    elsif t = trailers
      stream.send_trailers(t)
    end
    nil
  end
end

private OK_HEADERS = [{":status", "200"}, {"content-type", "application/grpc"}]

private def message_frame(message = EchoResponse.new(message: "fake")) : Bytes
  GRPC::Framing.encode(message.to_protobuf)
end

describe "GRPC client protocol handling" do
  {404 => GRPC::StatusCode::Unimplemented, 503 => GRPC::StatusCode::Unavailable,
   401 => GRPC::StatusCode::Unauthenticated, 403 => GRPC::StatusCode::PermissionDenied,
   429 => GRPC::StatusCode::Unavailable, 400 => GRPC::StatusCode::Internal,
   500 => GRPC::StatusCode::Unknown}.each do |http, code|
    it "maps HTTP #{http} without grpc-status to #{code}" do
      handler = ->(context : HTTP2::Server::Context) do
        context.request.body.gets_to_end
        context.response.status = http
        context.response.headers["content-type"] = "text/html"
        context.response.print "<html>error</html>"
        nil
      end
      with_fake_server(handler) do |client|
        error = GRPCSpec.expect_status(code) { client.unary(EchoRequest.new) }
        error.status.message.should contain http.to_s
        GRPCSpec.expect_status(code) { client.server_stream(EchoRequest.new).to_a }
      end
    end
  end

  it "prefers grpc-status over the HTTP status" do
    with_fake_server(respond_raw([{":status", "200"}, {"content-type", "application/grpc"}, {"grpc-status", "7"}, {"grpc-message", "nope%21"}])) do |client|
      error = GRPCSpec.expect_status(GRPC::StatusCode::PermissionDenied) { client.unary(EchoRequest.new) }
      error.status.message.should eq "nope!"
    end
  end

  it "fails with UNKNOWN for a non-gRPC content type" do
    with_fake_server(respond_raw([{":status", "200"}, {"content-type", "text/html"}], [message_frame], [{"grpc-status", "0"}])) do |client|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Unknown) { client.unary(EchoRequest.new) }
      error.status.message.should contain "content-type"
    end
  end

  it "fails with INTERNAL when trailers lack grpc-status" do
    with_fake_server(respond_raw(OK_HEADERS, [message_frame], [{"x-other", "1"}])) do |client|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Internal) { client.unary(EchoRequest.new) }
      error.status.message.should contain "grpc-status"
    end
  end

  it "fails with INTERNAL when the stream ends without trailers" do
    with_fake_server(respond_raw(OK_HEADERS, [message_frame])) do |client|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Internal) { client.unary(EchoRequest.new) }
      error.status.message.should contain "trailers"
      GRPCSpec.expect_status(GRPC::StatusCode::Internal) { client.server_stream(EchoRequest.new).to_a }
    end
  end

  it "maps unknown grpc-status values to UNKNOWN" do
    ["99", "abc", "-1"].each do |value|
      with_fake_server(respond_raw(OK_HEADERS, [message_frame], [{"grpc-status", value}])) do |client|
        GRPCSpec.expect_status(GRPC::StatusCode::Unknown) { client.unary(EchoRequest.new) }
      end
    end
  end

  it "decodes status details from grpc-status-details-bin" do
    with_fake_server(respond_raw(OK_HEADERS, trailers: [{"grpc-status", "3"}, {"grpc-status-details-bin", "AQID"}])) do |client|
      error = GRPCSpec.expect_status(GRPC::StatusCode::InvalidArgument) { client.unary(EchoRequest.new) }
      error.details.should eq Bytes[1, 2, 3]
    end
  end

  it "fails unary calls with INTERNAL for zero or several response messages" do
    with_fake_server(respond_raw(OK_HEADERS, [] of Bytes, [{"grpc-status", "0"}])) do |client|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Internal) { client.unary(EchoRequest.new) }
      error.status.message.should contain "No response message"
      GRPCSpec.expect_status(GRPC::StatusCode::Internal) { client.client_stream.close_and_receive }
    end
    with_fake_server(respond_raw(OK_HEADERS, [message_frame, message_frame], [{"grpc-status", "0"}])) do |client|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Internal) { client.unary(EchoRequest.new) }
      error.status.message.should contain "more than one"
    end
  end

  it "fails with INTERNAL for unparseable response messages" do
    with_fake_server(respond_raw(OK_HEADERS, [GRPC::Framing.encode(Bytes[0xff, 0xff])], [{"grpc-status", "0"}])) do |client|
      error = GRPCSpec.expect_status(GRPC::StatusCode::Internal) { client.unary(EchoRequest.new) }
      error.status.message.should contain "parse"
    end
  end

  it "fails with INTERNAL for compressed responses without grpc-encoding" do
    with_fake_server(respond_raw(OK_HEADERS, [GRPC::Framing.encode(EchoResponse.new.to_protobuf, "gzip")], [{"grpc-status", "0"}])) do |client|
      GRPCSpec.expect_status(GRPC::StatusCode::Internal) { client.unary(EchoRequest.new) }
    end
  end

  it "fails with INTERNAL for a truncated response message" do
    with_fake_server(respond_raw(OK_HEADERS, [message_frame[0, 6]], [{"grpc-status", "0"}])) do |client|
      GRPCSpec.expect_status(GRPC::StatusCode::Internal) { client.unary(EchoRequest.new) }
    end
  end

  {HTTP2::ErrorCode::CANCEL            => GRPC::StatusCode::Cancelled,
   HTTP2::ErrorCode::ENHANCE_YOUR_CALM => GRPC::StatusCode::ResourceExhausted,
   HTTP2::ErrorCode::INTERNAL_ERROR    => GRPC::StatusCode::Internal,
   HTTP2::ErrorCode::PROTOCOL_ERROR    => GRPC::StatusCode::Internal}.each do |reset, code|
    it "maps RST_STREAM #{reset} to #{code}" do
      with_fake_server(respond_raw(OK_HEADERS, [message_frame], reset: reset)) do |client|
        call = client.server_stream(EchoRequest.new)
        error = GRPCSpec.expect_status(code) { call.to_a }
        error.status.message.should contain reset.to_s
      end
    end
  end
end
